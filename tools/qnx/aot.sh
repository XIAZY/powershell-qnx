#!/bin/sh
# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.
#
# Compiles the libraries listed in hot-libraries.txt ahead of time, in place,
# in a QNX install tree:
#
#     aot.sh <mono-aot-cross> <install tree> <logs directory>
#
# QNX_ARCH (x86 by default, or arm) is the tree's architecture, the one the
# AOT cross compiler was built for.
#
# Normal AOT images (not full AOT): the runtime JIT-compiles what they lack.
# The profiles in profiles/ are added, so that the generic instances the
# recorded runs used are compiled into the images of the libraries that use
# them, and native-wrappers puts the P/Invoke, internal call and JIT icall
# wrappers into the images. System.Private.CoreLib is compiled first, with
# nothing else on MONO_PATH, as the runtime's own builds do.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
compiler=$1 tree=$(cd "$2" && pwd) logs=$3
mkdir -p "$logs"

# How each architecture's images are assembled and linked. QNX's loaders: SysV
# hash only, no GNU stack or RELRO notes; ARM: QNX's softfp ABI, and two LOAD
# segments at 4 KiB, as eng/native/qnx/toolchain.cmake links.
case ${QNX_ARCH:-x86} in
x86)
	cc_flags="--target=i386-pc-linux-gnu"
	ld_flags="-m elf_i386"
	mtriple=
	;;
arm)
	# The triple gives the AOT compiler QNX's ARM EABI calling convention, as
	# the runtime's JIT uses it.
	mtriple=",mtriple=armv7-unknown-nto-qnx6.5.0eabi"
	cc_flags="--target=armv7-pc-linux-gnueabi -march=armv7-a -mfpu=vfpv3 -mfloat-abi=softfp"
	ld_flags="-m armelf -z max-page-size=0x1000"
	;;
*)
	echo "aot.sh: QNX_ARCH must be x86 or arm" >&2
	exit 2
	;;
esac

options="nimt-trampolines=4096,native-wrappers$mtriple"
for p in "$here"/profiles/*.aotprofile; do
	options="$options,profile=$p"
done

# compile <assembly>: assembly.dll -> assembly.dll.so next to it
compile() {
	dll=$1
	log=$logs/$(basename "$dll").log
	"$compiler" --aot="$options,asmonly,outfile=$dll.s" "$dll" > "$log" 2>&1
	clang $cc_flags -c -o "$dll.o" "$dll.s" >> "$log" 2>&1
	ld.lld -shared $ld_flags --hash-style=sysv -z norelro -z nognustack --no-rosegment \
		-o "$dll.so" "$dll.o" >> "$log" 2>&1
	llvm-strip --strip-all "$dll.so"
	rm -f "$dll.s" "$dll.o"
	echo "  $(basename "$dll").so"
}

alone=$tree/shared/.corelib
rm -rf "$alone"
mkdir "$alone"
ln "$tree/shared/System.Private.CoreLib.dll" "$alone/"
MONO_PATH=$alone compile "$alone/System.Private.CoreLib.dll"
mv "$alone/System.Private.CoreLib.dll.so" "$tree/shared/"
rm -rf "$alone"

MONO_PATH=$tree/pwsh:$tree/shared
export MONO_PATH
grep -v '^#' "$here/hot-libraries.txt" | grep -v '^$' > "$logs/libraries"
while read -r name; do
	[ "$name" = System.Private.CoreLib ] && continue
	if [ -f "$tree/shared/$name.dll" ]; then
		compile "$tree/shared/$name.dll"
	elif [ -f "$tree/pwsh/$name.dll" ]; then
		compile "$tree/pwsh/$name.dll"
	else
		echo "aot.sh: $name.dll is not in $tree" >&2
		exit 2
	fi
done < "$logs/libraries"
