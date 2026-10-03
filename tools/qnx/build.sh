#!/usr/bin/env bash
# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.
#
# Builds PowerShell for QNX Neutrino, 6.5.0 on x86 or BlackBerry 10's on
# 32-bit ARM, from this repository and the QNX port of dotnet/runtime pinned
# in tools/qnx/runtime.json, into an install tree and its archive. See
# docs/building/qnx.md.
#
#     tools/qnx/build.sh [output directory]      (default: out/qnx)
#
# Environment:
#   QNX_ARCH         x86 (default): QNX Neutrino 6.5.0 on x86; arm: QNX on
#                    32-bit ARMv7, as on BlackBerry 10
#   QNX_ROOTFS       a QNX rootfs for that architecture, made with the runtime's
#                    eng/native/qnx/build-rootfs.sh from your QNX SDP 6.5.0
#                    (x86) or BlackBerry 10 Native SDK (arm) (required; see the
#                    docs)
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
arch=${QNX_ARCH:-x86}
qnxrootfs=${QNX_ROOTFS:?set QNX_ROOTFS to a QNX rootfs (see docs/building/qnx.md)}
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

# Per architecture: the runtime identifier of the managed libraries, the AOT
# cross compiler's triple, and the OpenSSL target.
case $arch in
x86)
	rid=linux-x86
	aot_triple=i686-pc-nto-qnx6.5.0
	openssl_target=qnx650-x86
	;;
arm)
	rid=linux-arm
	aot_triple=armv7-unknown-nto-qnx6.5.0eabi
	openssl_target=bb10-armv7
	# The linux-arm root filesystem dotnet/runtime cross-builds with, pinned.
	crossrootfs_image=mcr.microsoft.com/dotnet-buildtools/prereqs:azurelinux-3.0-net10.0-cross-arm@sha256:575c0fe7a1d175842d95fba861e5f875cbe7b07bb18700b405884d0825e32ce5
	;;
*) echo "build.sh: QNX_ARCH must be x86 or arm" >&2; exit 2 ;;
esac

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
# /qnx-rootfs (as ROOTFS_DIR), compiling with clang for the architecture.
in_container() {
	docker run --rm --user "$uid" -e HOME=/out/.home -e DOTNET_CLI_HOME=/out/.home \
		-e ROOTFS_DIR=/qnx-rootfs -e CC=clang -e CXX=clang++ -e TARGET_BUILD_ARCH="$arch" -e QNX_ARCH="$arch" \
		-v "$qnxrootfs":/qnx-rootfs:ro -v "$out":/out -v "$runtime":/out/runtime -v "$repo":/repo \
		-w /out powershell-qnx-build "$@"
}

if [[ ! -f $qnxrootfs/usr/include/sys/neutrino.h ]]; then
	echo "build.sh: $qnxrootfs is not a QNX rootfs (see docs/building/qnx.md)" >&2
	exit 2
fi

step "container images"
docker build -q -t powershell-qnx-build -f "$qnx/docker/build.Dockerfile" "$qnx/docker"
if [[ $arch == x86 ]]; then
	docker build -q --platform linux/386 -t powershell-qnx-rootfs-x86 -f "$qnx/docker/rootfs-x86.Dockerfile" "$qnx/docker"
fi
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

if [[ $arch == x86 ]]; then
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
	linux_rootfs=$out/rootfs-x86 linux_rootfs_mount=/rootfs
else
	step "linux-arm root filesystem for the linux-arm managed libraries ($crossrootfs_image)"
	# The image's files only: nothing in it runs. Its links are absolute,
	# under /crossrootfs/arm, so the build sees it there, as upstream's does.
	if [[ ! -d $out/rootfs-arm/usr ]]; then
		mkdir -p "$out/rootfs-arm"
		cid=$(docker create --platform linux/amd64 "$crossrootfs_image")
		docker export "$cid" | tar -x -C "$out/rootfs-arm" --strip-components=2 crossrootfs/arm
		docker rm "$cid" >/dev/null
	fi
	linux_rootfs=$out/rootfs-arm linux_rootfs_mount=/crossrootfs/arm
fi

step "$rid managed libraries (the runtime's own build, unmodified managed code)"
# NuGetAudit: advisories published after the release against the build's own
# tooling packages would otherwise fail the build (NU1903 as an error).
pack=$runtime/artifacts/bin/microsoft.netcore.app.runtime.$rid/Release/runtimes/$rid
if [[ ! -f $pack/native/System.Private.CoreLib.dll ]]; then
	docker run --rm --user "$uid" -e HOME=/out/.home -e ROOTFS_DIR=$linux_rootfs_mount \
		-v "$linux_rootfs":$linux_rootfs_mount:ro -v "$out":/out -v "$runtime":/out/runtime -w /out/runtime powershell-qnx-build \
		./build.sh mono+libs -os linux -arch $arch -c Release -cross -p:NuGetAudit=false
fi
rm -rf "$out/framework"
mkdir -p "$out/framework"
cp "$pack"/lib/net*/*.dll "$pack/native/System.Private.CoreLib.dll" "$out/framework/"

step "OpenSSL $openssl_version for QNX (static libraries)"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" \
	"openssl-$openssl_version.tar.gz" "$openssl_sha256"
openssl_out=$out/openssl-qnx-$arch
if [[ ! -f $openssl_out/lib/libcrypto.a ]]; then
	rm -rf "$out/openssl-$openssl_version" "$out/openssl-build"
	tar xzf "$out/openssl-$openssl_version.tar.gz" -C "$out"
	mkdir -p "$out/openssl-build"
	# no-async: QNX has no makecontext/swapcontext. no-module: the legacy
	# provider and engines are built in, not loaded. no-pinshared: QNX 6.5's
	# dladdr succeeds for an address in the executable with a NULL dli_fname,
	# which OpenSSL's self-pinning dereferences; there is no shared library to
	# pin. Only the static libraries and headers are built and installed.
	# ARM: no-asm, and only the libraries (see tools/qnx/openssl/bb10-armv7.conf).
	if [[ $arch == x86 ]]; then
		in_container sh -c "
			cd openssl-build &&
			perl ../openssl-$openssl_version/Configure $openssl_target --config=/repo/tools/qnx/openssl/$openssl_target.conf \
				--prefix=/out/openssl-qnx-$arch --libdir=lib --openssldir=/etc/ssl \
				no-shared no-module no-pinshared no-async no-tests no-docs AR=llvm-ar RANLIB=llvm-ranlib >/dev/null &&
			make -j $jobs build_libs >/dev/null && make install_dev >/dev/null"
	else
		in_container sh -c "
			cd openssl-build &&
			perl ../openssl-$openssl_version/Configure $openssl_target --config=/repo/tools/qnx/openssl/$openssl_target.conf \
				--prefix=/out/openssl-qnx-$arch --libdir=lib --openssldir=/etc/ssl \
				no-shared no-module no-pinshared no-async no-asm no-tests no-docs AR=llvm-ar RANLIB=llvm-ranlib >/dev/null &&
			make -j $jobs build_generated libcrypto.a libssl.a >/dev/null &&
			mkdir -p /out/openssl-qnx-$arch/lib /out/openssl-qnx-$arch/include/openssl &&
			cp libcrypto.a libssl.a /out/openssl-qnx-$arch/lib/ &&
			cp ../openssl-$openssl_version/include/openssl/*.h include/openssl/*.h /out/openssl-qnx-$arch/include/openssl/"
	fi
fi

step "Mono, qnxhost and the native libraries for QNX (the runtime's build -os qnx)"
mono_qnx=$runtime/artifacts/bin/mono/qnx.$arch.Release
native_qnx=$runtime/artifacts/bin/native/net10.0-qnx-Release-$arch
in_container sh -c "cd runtime && ./build.sh -os qnx -arch $arch -cross -c Release -subset mono.runtime+libs.native \
	-cmakeargs '-DOPENSSL_ROOT_DIR=/out/openssl-qnx-$arch -DOPENSSL_INCLUDE_DIR=/out/openssl-qnx-$arch/include \
		-DOPENSSL_CRYPTO_LIBRARY=/out/openssl-qnx-$arch/lib/libcrypto.a -DOPENSSL_SSL_LIBRARY=/out/openssl-qnx-$arch/lib/libssl.a' >/dev/null"

step "the AOT cross compiler for QNX"
in_container sh -c "
	python3 runtime/src/mono/mono/offsets/offsets-tool.py --abi=$aot_triple \
		--targetdir=/out/runtime/artifacts/obj/mono/qnx.$arch.Release --monodir=/out/runtime/src/mono \
		--nativedir=/out/runtime/src/native --outfile=/out/offsets-$aot_triple.h \
		--libclang=\$(ls /usr/lib/llvm-*/lib/libclang-*.so.1 | sort -V | tail -1) \
		--sysroot=/qnx-rootfs --prefix=/out/runtime/eng/native/qnx >/dev/null &&
	cmake -G Ninja -S runtime/src/mono -B aot-cross-$arch -DCMAKE_BUILD_TYPE=Release \
		-DAOT_TARGET_TRIPLE=$aot_triple -DAOT_OFFSETS_FILE=/out/offsets-$aot_triple.h \
		-DENABLE_MINIMAL= -DENABLE_ICALL_SYMBOL_MAP=1 -DDISABLE_SHARED_LIBS=1 -DDISABLE_LIBS=1 \
		-DAOT_COMPONENTS=1 -DSTATIC_COMPONENTS=1 -DGC_SUSPEND=preemptive \
		-DMONO_CROSS_COMPILE_EXECUTABLE_NAME=1 -DCLR_CMAKE_HOST_ARCH=$host_arch >/dev/null &&
	cmake --build aot-cross-$arch -- -j $jobs >/dev/null"

step "libpsl-native"
in_container sh -c "
	cmake -G Ninja -S /repo/src/qnx/libpsl-native -B psl-native-qnx-$arch -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_TOOLCHAIN_FILE=/out/runtime/eng/native/qnx/toolchain.cmake >/dev/null &&
	cmake --build psl-native-qnx-$arch >/dev/null"

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
# QNX 6.5 has no time-zone database, so .NET would know only UTC (BlackBerry
# 10's has a few dozen zones). The zones
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
tree=$out/powershell-qnx-$arch
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
python3 "$qnx/deploy.py" --tree --out "$tree" --framework "$out/framework" --rid "$rid" \
	--native "$mono_qnx/libcoreclr.so" \
	"$native_qnx/libSystem.Native.so" \
	"$native_qnx/libSystem.IO.Compression.Native.so" \
	"$native_qnx/libSystem.Security.Cryptography.Native.OpenSsl.so" \
	"$out/psl-native-qnx-$arch/libpsl-native.so" \
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
cp "$qnx/README.tree.md" "$tree/README.md"

step "AOT images"
in_container sh /repo/tools/qnx/aot.sh /out/aot-cross-$arch/mono/mini/mono-aot-cross /out/powershell-qnx-$arch /out/aot-logs-$arch

step "archive"
tar czf "$out/powershell-$pwsh_version-qnx-$arch.tar.gz" -C "$tree" .
ls -l "$out/powershell-$pwsh_version-qnx-$arch.tar.gz"
echo "Copy it to the QNX machine, unpack it, and run ./install.sh as root, or ./pwsh/pwsh in place (see docs/qnx/README.md)."
