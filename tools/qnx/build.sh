#!/usr/bin/env bash
# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.
#
# Builds PowerShell for QNX Neutrino 6.5.0 on x86, from this repository and
# the QNX port of dotnet/runtime pinned in tools/qnx/runtime.json, into an
# install tree and its archive. See docs/building/qnx.md.
#
#     tools/qnx/build.sh [output directory]      (default: out/qnx)
#
# Environment:
#   QNX_ROOTFS       a QNX Neutrino 6.5.0 x86 rootfs, made from your QNX SDP 6.5.0
#                    with the runtime's eng/native/qnx/build-rootfs.sh (required;
#                    see the docs)
#   PWSH_SOURCE      source (default): build PowerShell from this repository
#                    with build.psm1, which needs pwsh and the .NET SDK on the
#                    build host; release: use the official framework-dependent
#                    release of the same version, verified by its SHA-256
#   JOBS             parallel build jobs (default: the number of processors)
#   RUNTIME_DIR      an existing runtime checkout to build instead of cloning
#                    the pinned one (for work on the runtime itself)
#
# Needs docker, git, curl, python3, and a Linux build host (x64 or arm64).
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
qnx=$repo/tools/qnx
out=$(mkdir -p "${1:-$repo/out/qnx}" && cd "${1:-$repo/out/qnx}" && pwd)
qnxrootfs=${QNX_ROOTFS:?set QNX_ROOTFS to a QNX 6.5.0 x86 rootfs (see docs/building/qnx.md)}
pwsh_source=${PWSH_SOURCE:-source}
jobs=${JOBS:-$(nproc)}
uid=$(id -u):$(id -g)
runtime=${RUNTIME_DIR:-$out/runtime}

pwsh_version=7.6.6
pwsh_release_url=https://github.com/PowerShell/PowerShell/releases/download/v$pwsh_version/powershell-$pwsh_version-linux-x64-fxdependent.tar.gz
pwsh_release_sha256=7e851d01dba116269d1e7f4505ef7b54bfa6c0b5b08965b67ac229503154a9da
openssl_version=3.5.9
openssl_sha256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
cacert=cacert-2026-09-25.pem
cacert_sha256=a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
tz_version=2026e
tzdata_sha256=b26882805f26aac59d5b222978e6580484b834ccdc98be89df2f05a6dc53a652
tzcode_sha256=cc3d27ca2a0d8399504551b920970d80af83bfb9c216e8082a15491921935d54

read -r runtime_repo runtime_tag runtime_commit < <(python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
print(p["repository"], p["tag"], p["commit"])' "$qnx/runtime.json")

case $(uname -m) in
x86_64) host_arch=x64 ;;
aarch64 | arm64) host_arch=arm64 ;;
*) echo "build.sh: unsupported build host architecture $(uname -m)" >&2; exit 2 ;;
esac

step() { printf '\n== %s\n' "$*"; }

# Downloads a file into the output directory once and verifies it:
# URL, file name, SHA-256.
fetch() {
	if [[ ! -f $out/$2 ]]; then
		curl -sSL -o "$out/$2.part" "$1"
		mv "$out/$2.part" "$out/$2"
	fi
	echo "$3  $out/$2" | sha256sum -c -
}

# Runs a command in the build container, with the output directory at /out,
# the runtime at /out/runtime, this repository at /repo and the QNX rootfs at
# /qnx-rootfs (as ROOTFS_DIR), compiling with clang.
in_container() {
	docker run --rm --user "$uid" -e HOME=/out/.home -e DOTNET_CLI_HOME=/out/.home \
		-e ROOTFS_DIR=/qnx-rootfs -e CC=clang -e CXX=clang++ \
		-v "$qnxrootfs":/qnx-rootfs:ro -v "$out":/out -v "$runtime":/out/runtime -v "$repo":/repo \
		-w /out powershell-qnx-build "$@"
}

if [[ ! -f $qnxrootfs/usr/include/sys/neutrino.h ]]; then
	echo "build.sh: $qnxrootfs is not a QNX 6.5.0 rootfs (see docs/building/qnx.md)" >&2
	exit 2
fi

step "container images"
docker build -q -t powershell-qnx-build -f "$qnx/docker/build.Dockerfile" "$qnx/docker"
docker build -q --platform linux/386 -t powershell-qnx-rootfs-x86 -f "$qnx/docker/rootfs-x86.Dockerfile" "$qnx/docker"
mkdir -p "$out/.home"

if [[ -n ${RUNTIME_DIR:-} ]]; then
	step "runtime from $runtime ($(git -C "$runtime" log --oneline -1))"
else
	step "runtime $runtime_tag from $runtime_repo"
	if [[ ! -d $runtime ]]; then
		git clone -q --depth 1 -b "$runtime_tag" "$runtime_repo" "$runtime"
	fi
	actual=$(git -C "$runtime" rev-parse HEAD)
	if [[ $actual != "$runtime_commit"* ]]; then
		echo "build.sh: $runtime_tag is $actual, not the pinned $runtime_commit" >&2
		exit 2
	fi
fi

step "i386 root filesystem for the linux-x86 managed libraries"
if [[ ! -d $out/rootfs-x86/usr ]]; then
	mkdir -p "$out/rootfs-x86"
	cid=$(docker create --platform linux/386 powershell-qnx-rootfs-x86)
	docker export "$cid" | tar -x -C "$out/rootfs-x86" --exclude=dev
	docker rm "$cid" >/dev/null
	# A sysroot needs relative symbolic links: absolute ones would point into the build host.
	python3 - "$out/rootfs-x86" <<'EOF'
import os, sys
root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root):
    for name in dirnames + filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path) and os.readlink(path).startswith("/"):
            target = os.path.join(root, os.readlink(path).lstrip("/"))
            os.unlink(path)
            os.symlink(os.path.relpath(target, dirpath), path)
EOF
fi

step "linux-x86 managed libraries (the runtime's own build, unmodified managed code)"
# NuGetAudit: advisories published after the release against the build's own
# tooling packages would otherwise fail the build (NU1903 as an error).
pack=$runtime/artifacts/bin/microsoft.netcore.app.runtime.linux-x86/Release/runtimes/linux-x86
if [[ ! -f $pack/native/System.Private.CoreLib.dll ]]; then
	docker run --rm --user "$uid" -e HOME=/out/.home -e ROOTFS_DIR=/rootfs \
		-v "$out/rootfs-x86":/rootfs:ro -v "$out":/out -v "$runtime":/out/runtime -w /out/runtime powershell-qnx-build \
		./build.sh mono+libs -os linux -arch x86 -c Release -cross -p:NuGetAudit=false
fi
rm -rf "$out/framework"
mkdir -p "$out/framework"
cp "$pack"/lib/net*/*.dll "$pack/native/System.Private.CoreLib.dll" "$out/framework/"

step "OpenSSL $openssl_version for QNX (static libraries)"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" \
	"openssl-$openssl_version.tar.gz" "$openssl_sha256"
if [[ ! -f $out/openssl-qnx/lib/libcrypto.a ]]; then
	rm -rf "$out/openssl-$openssl_version" "$out/openssl-build"
	tar xzf "$out/openssl-$openssl_version.tar.gz" -C "$out"
	mkdir -p "$out/openssl-build"
	# no-async: QNX 6.5 has no makecontext/swapcontext. no-module: the legacy
	# provider and engines are built in, not loaded. no-pinshared: QNX 6.5's
	# dladdr succeeds for an address in the executable with a NULL dli_fname,
	# which OpenSSL's self-pinning dereferences; there is no shared library to
	# pin. Only the static libraries and headers are built and installed.
	in_container sh -c "
		cd openssl-build &&
		perl ../openssl-$openssl_version/Configure qnx650-x86 --config=/repo/tools/qnx/openssl/qnx650-x86.conf \
			--prefix=/out/openssl-qnx --libdir=lib --openssldir=/etc/ssl \
			no-shared no-module no-pinshared no-async no-tests no-docs AR=llvm-ar RANLIB=llvm-ranlib >/dev/null &&
		make -j $jobs build_libs >/dev/null && make install_dev >/dev/null"
fi

step "Mono, qnxhost and the native libraries for QNX (the runtime's build -os qnx)"
mono_qnx=$runtime/artifacts/bin/mono/qnx.x86.Release
native_qnx=$runtime/artifacts/bin/native/net10.0-qnx-Release-x86
in_container sh -c "cd runtime && ./build.sh -os qnx -arch x86 -cross -c Release -subset mono.runtime+libs.native \
	-cmakeargs '-DOPENSSL_ROOT_DIR=/out/openssl-qnx -DOPENSSL_INCLUDE_DIR=/out/openssl-qnx/include \
		-DOPENSSL_CRYPTO_LIBRARY=/out/openssl-qnx/lib/libcrypto.a -DOPENSSL_SSL_LIBRARY=/out/openssl-qnx/lib/libssl.a' >/dev/null"

step "the AOT cross compiler for QNX"
in_container sh -c "
	python3 runtime/src/mono/mono/offsets/offsets-tool.py --abi=i686-pc-nto-qnx6.5.0 \
		--targetdir=/out/runtime/artifacts/obj/mono/qnx.x86.Release --monodir=/out/runtime/src/mono \
		--nativedir=/out/runtime/src/native --outfile=/out/offsets-i686-pc-nto-qnx6.5.0.h \
		--libclang=\$(ls /usr/lib/llvm-*/lib/libclang-*.so.1 | sort -V | tail -1) \
		--sysroot=/qnx-rootfs --prefix=/out/runtime/eng/native/qnx >/dev/null &&
	cmake -G Ninja -S runtime/src/mono -B aot-cross -DCMAKE_BUILD_TYPE=Release \
		-DAOT_TARGET_TRIPLE=i686-pc-nto-qnx6.5.0 -DAOT_OFFSETS_FILE=/out/offsets-i686-pc-nto-qnx6.5.0.h \
		-DENABLE_MINIMAL= -DENABLE_ICALL_SYMBOL_MAP=1 -DDISABLE_SHARED_LIBS=1 -DDISABLE_LIBS=1 \
		-DAOT_COMPONENTS=1 -DSTATIC_COMPONENTS=1 -DGC_SUSPEND=preemptive \
		-DMONO_CROSS_COMPILE_EXECUTABLE_NAME=1 -DCLR_CMAKE_HOST_ARCH=$host_arch >/dev/null &&
	cmake --build aot-cross -- -j $jobs >/dev/null"

step "libpsl-native"
in_container sh -c "
	cmake -G Ninja -S /repo/src/qnx/libpsl-native -B psl-native-qnx -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_TOOLCHAIN_FILE=/out/runtime/eng/native/qnx/toolchain.cmake >/dev/null &&
	cmake --build psl-native-qnx >/dev/null"

step "PowerShell $pwsh_version ($pwsh_source)"
rm -rf "$out/powershell"
mkdir -p "$out/powershell"
case $pwsh_source in
source)
	command -v pwsh >/dev/null || {
		echo "build.sh: building from source needs pwsh on the build host; or set PWSH_SOURCE=release" >&2
		exit 2
	}
	(cd "$repo" && pwsh -NoProfile -NonInteractive -Command "
		\$ErrorActionPreference = 'Stop'
		Import-Module ./build.psm1
		# Only the SDK: Start-PSBootstrap -Scenario DotNet also installs the
		# dotnet-format tool, which the build does not need and which fails
		# to install when a newer one is already there.
		Install-Dotnet
		Find-Dotnet
		Start-PSBuild -Configuration Release -Runtime fxdependent -ReleaseTag v$pwsh_version -UseNuGetOrg -Output '$out/powershell'")
	;;
release)
	curl -sSL -o "$out/powershell.tar.gz" "$pwsh_release_url"
	echo "$pwsh_release_sha256  $out/powershell.tar.gz" | sha256sum -c -
	tar xzf "$out/powershell.tar.gz" -C "$out/powershell"
	;;
*) echo "build.sh: PWSH_SOURCE must be source or release" >&2; exit 2 ;;
esac

step "CA certificates ($cacert, Mozilla's bundle as curl publishes it)"
fetch "https://curl.se/ca/$cacert" "$cacert" "$cacert_sha256"

step "time zone data (IANA tz $tz_version)"
# QNX 6.5 has no time-zone database, so .NET would know only UTC. The zones
# are compiled with the zic of the same release, built here, so the output
# does not depend on the build host's zic; the right/ and posix/ duplicate
# trees are left out.
fetch "https://data.iana.org/time-zones/releases/tzdata$tz_version.tar.gz" "tzdata$tz_version.tar.gz" "$tzdata_sha256"
fetch "https://data.iana.org/time-zones/releases/tzcode$tz_version.tar.gz" "tzcode$tz_version.tar.gz" "$tzcode_sha256"
rm -rf "$out/tz" "$out/zoneinfo"
mkdir -p "$out/tz" "$out/zoneinfo"
tar xzf "$out/tzcode$tz_version.tar.gz" -C "$out/tz"
tar xzf "$out/tzdata$tz_version.tar.gz" -C "$out/tz"
in_container sh -c "make -s -C tz zic >/dev/null && cd tz && ./zic -d /out/zoneinfo -b fat \
	africa antarctica asia australasia europe northamerica southamerica etcetera backward factory"
cp "$out/tz/zone.tab" "$out/tz/zone1970.tab" "$out/tz/iso3166.tab" "$out/zoneinfo/"

step "install tree"
tree=$out/powershell-qnx
rm -rf "$tree"
# TERMINFO: QNX keeps terminfo in /usr/lib/terminfo, where .NET does not look.
# QNXHOST_MODE: AOT images where they exist, the JIT for the rest.
# SSL_CERT_FILE, SSL_CERT_DIR: OpenSSL's trust store, in the install tree.
# TZDIR: the IANA time zones, in the install tree.
# POWERSHELL_DIAGNOSTICS_OPTOUT: no host IPC listener, the Unix socket every
# PowerShell process would otherwise create at startup and delete at exit
# (see docs/qnx/README.md).
# POWERSHELL_TELEMETRY_OPTOUT, POWERSHELL_UPDATECHECK: this build does not send
# PowerShell's telemetry or check for (Linux) updates at startup.
python3 "$qnx/deploy.py" --tree --out "$tree" --framework "$out/framework" \
	--native "$mono_qnx/libcoreclr.so" \
	"$native_qnx/libSystem.Native.so" \
	"$native_qnx/libSystem.IO.Compression.Native.so" \
	"$native_qnx/libSystem.Security.Cryptography.Native.OpenSsl.so" \
	"$out/psl-native-qnx/libpsl-native.so" \
	--host "$mono_qnx/qnxhost" \
	--defaultenv TERMINFO=/usr/lib/terminfo --defaultenv QNXHOST_MODE=jit \
	--defaultenv 'SSL_CERT_FILE=$ROOT/etc/ssl/cert.pem' --defaultenv 'SSL_CERT_DIR=$ROOT/etc/ssl/certs' \
	--defaultenv 'TZDIR=$ROOT/etc/zoneinfo' \
	--defaultenv POWERSHELL_DIAGNOSTICS_OPTOUT=1 \
	--defaultenv POWERSHELL_TELEMETRY_OPTOUT=1 --defaultenv POWERSHELL_UPDATECHECK=Off \
	"$out/powershell/pwsh.dll"
mkdir -p "$tree/etc/ssl/certs"
cp "$out/$cacert" "$tree/etc/ssl/cert.pem"
cp -R "$out/zoneinfo" "$tree/etc/zoneinfo"
cp "$qnx/install.sh" "$tree/install.sh"

step "AOT images"
in_container sh /repo/tools/qnx/aot.sh /out/aot-cross/mono/mini/mono-aot-cross /out/powershell-qnx /out/aot-logs

step "archive"
tar czf "$out/powershell-$pwsh_version-qnx-x86.tar.gz" -C "$tree" .
ls -l "$out/powershell-$pwsh_version-qnx-x86.tar.gz"
echo "Copy it to the QNX machine, unpack it, and run ./install.sh as root, or ./pwsh/pwsh in place (see docs/qnx/README.md)."
