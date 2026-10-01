# Build PowerShell for QNX Neutrino 6.5.0 (x86)

This guide builds an install tree of PowerShell for QNX Neutrino 6.5.0 on
32-bit x86, cross-compiled on a Linux host. PowerShell runs on QNX on the
Mono runtime from the QNX port of dotnet/runtime
([XIAZY/runtime-qnx](https://github.com/XIAZY/runtime-qnx)). The .NET
managed libraries are used unmodified, and PowerShell's own sources carry
only the general fixes listed in
[docs/qnx](../qnx/README.md#changes-to-powershell-itself).

For what works on QNX and how to run it, see [docs/qnx](../qnx/README.md).

## Licensing of the QNX parts

Building for QNX needs the QNX Software Development Platform (SDP) 6.5.0
headers and libraries (made into the "rootfs" below). **They are proprietary to BlackBerry
QNX and are not part of this repository or of anything it publishes.**
You need your own licensed copy of QNX SDP 6.5.0. The install tree you build
links against it; distributing that tree is subject to your QNX licence.

## Prerequisites

- A Linux build host, x64 or arm64, with:
  - Docker (the runtime is built in a container; on an arm64 host the
    linux-x86 root filesystem needs QEMU user-mode emulation registered with
    binfmt_misc)
  - git, curl and Python 3
  - clang, ld.lld and the LLVM binutils, version 15 or later
  - for building PowerShell from source: [PowerShell](linux.md) (`pwsh`) on
    the build host; the script installs the .NET SDK it needs
- A QNX 6.5.0 x86 rootfs made from your QNX SDP 6.5.0 (below).
- About 40 GB of disk space and two hours on a 6-core machine.

### The QNX rootfs

The runtime cross-builds for QNX from a rootfs, as it does for its other
cross targets: the SDP's x86 headers and libraries, and gcc 4.4.2's startup
files and `libgcc.a`, in the layout of an installed QNX system. The runtime
repository's `eng/native/qnx/build-rootfs.sh` makes it, either from a local
SDP installation or over ssh from a QNX 6.5.0 machine that has the
self-hosted SDP installed:

```sh
git clone -b release/10.0 https://github.com/XIAZY/runtime-qnx.git
runtime-qnx/eng/native/qnx/build-rootfs.sh /path/to/qnx-rootfs /path/to/qnx650-sdp
runtime-qnx/eng/native/qnx/build-rootfs.sh /path/to/qnx-rootfs ssh:root@my-qnx-machine
```

## Build

```sh
git clone -b release/v7.6.6 https://github.com/XIAZY/powershell-qnx.git
cd powershell-qnx
export QNX_ROOTFS=/path/to/qnx-rootfs
tools/qnx/build.sh
```

The script:

1. clones the runtime at the tag and commit pinned in
   `tools/qnx/runtime.json`;
2. builds the linux-x86 managed libraries with the runtime's own build;
3. builds OpenSSL 3.5 as static libraries for QNX, verified by its
   SHA-256 (`tools/qnx/openssl` holds its QNX target);
4. builds Mono (`libcoreclr.so`), `qnxhost` (the host that replaces
   `dotnet` on QNX), `System.Native`, `System.IO.Compression.Native` and
   `System.Security.Cryptography.Native.OpenSsl` for QNX with the runtime's
   own build: `./build.sh -os qnx -arch x86 -cross -subset
   mono.runtime+libs.native`;
5. builds the AOT cross compiler for `i686-pc-nto-qnx6.5.0`. The runtime's
   build does not produce it for QNX yet, so the script configures it
   directly;
6. builds `libpsl-native`, PowerShell's native helper library, in C
   (`src/qnx/libpsl-native`), with the runtime's QNX toolchain;
7. builds PowerShell from this repository (`Start-PSBuild -Runtime
   fxdependent`);
8. assembles the install tree, with Mozilla's CA certificates as curl
   publishes them (dated and verified), and compiles the libraries listed in
   `tools/qnx/hot-libraries.txt` ahead of time, with the recorded profiles in
   `tools/qnx/profiles`.

The result is `out/qnx/powershell-7.6.6-qnx-x86.tar.gz`. A different output
directory can be given as the script's argument.

Without `pwsh` on the build host, `PWSH_SOURCE=release tools/qnx/build.sh`
uses the official framework-dependent release of PowerShell 7.6.6 instead,
verified by its SHA-256. The managed code is the same.

## Why the managed libraries are Linux's

.NET has no QNX target in its managed code: there is no `qnx` TargetOS for
the libraries and no `qnx-x86` runtime identifier. Rather than adding one,
which would mean building and maintaining a QNX variant of every library,
this port runs the stock linux-x86 managed libraries unmodified, with the
runtime identifier `linux-x86`. Everything QNX-specific is native: Mono runs
on QNX, and System.Native presents the Linux behaviour those libraries
expect, such as the `/proc` files they read, Linux errno values, and socket
and signal semantics. Code that checks `OperatingSystem.IsLinux()` therefore
sees `true` on QNX, while `RuntimeInformation.OSDescription` reports QNX.

## Install and run

On the QNX machine, as root:

```sh
mkdir /tmp/powershell && cd /tmp/powershell
gzip -dc /tmp/powershell-7.6.6-qnx-x86.tar.gz | tar xf -
./install.sh                # to /opt/powershell, with /usr/bin/pwsh
pwsh
```

`install.sh` copies the tree to `/opt/powershell` (`--prefix` for another
place) and links `/usr/bin/pwsh` to it (`--bindir`); `--login-shell` also
lists it in `/etc/shells`, and `--uninstall` removes what it made. Running it
again replaces an earlier install; it never replaces a `pwsh` or a directory
it did not make. Without it, the unpacked tree runs where it is
(`./pwsh/pwsh`): it is relocatable. See [docs/qnx](../qnx/README.md) for the launcher's
settings.
