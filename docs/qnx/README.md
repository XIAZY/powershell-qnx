# PowerShell on QNX Neutrino 6.5.0 (x86)

PowerShell 7.6 runs on QNX Neutrino 6.5.0 on 32-bit x86. This page describes
how it is put together, how to run it, and what does and does not work. To
build it, see [docs/building/qnx.md](../building/qnx.md).

The QNX SDP 6.5.0 headers and libraries the build links against are
proprietary to BlackBerry QNX: they are not distributed with this repository
or its releases, and you need your own licensed copy to build.

## How it works

- **Runtime:** Mono, from the QNX port of dotnet/runtime
  ([XIAZY/runtime-qnx](https://github.com/XIAZY/runtime-qnx)), branch
  `release/10.0`. The port adds QNX as a host for Mono and System.Native;
  the managed libraries are .NET's linux-x86 libraries, unmodified.
- **Launcher:** `bin/qnxhost`, from the runtime, replaces the `dotnet` host,
  which QNX cannot run. It reads the program's properties from `pwsh.props` (the trusted
  assemblies, search paths and runtime settings the `dotnet` host would
  pass), confines asynchronous signals to a thread of its own (QNX 6.5 cannot
  restart interrupted system calls), and starts the runtime on a thread with
  an 8 MiB stack.
- **Code:** sixteen libraries (System.Private.CoreLib,
  System.Management.Automation, the console host and others, listed in
  `tools/qnx/hot-libraries.txt`) are compiled ahead of time; the JIT compiles
  the rest. The runtime maps these images itself instead of with `dlopen`,
  so that only the pages used take memory: QNX's loader commits every page of
  a library at load.
- **libpsl-native:** PowerShell's native helper library, reimplemented in C
  for QNX (`src/qnx/libpsl-native`).
- **Cryptography and TLS:** `System.Security.Cryptography.Native.OpenSsl`
  with OpenSSL 3.5 linked in statically (QNX 6.5's own OpenSSL 0.9.8 is too
  old for .NET), and Mozilla's CA certificates in `etc/ssl/cert.pem`.

On a 2.8 GHz x86 machine, `pwsh -Command '$PSVersionTable'` takes about
0.8 s, the interactive prompt appears after about 1.2 s, and the process
uses about 70 MB at the prompt.

## Running

```sh
cd /opt/powershell
./bin/qnxhost pwsh.props                       # interactive
./bin/qnxhost pwsh.props -Command 'Get-Date'   # one command
./bin/qnxhost pwsh.props -File script.ps1
```

Arguments after `pwsh.props` are PowerShell's own.

| Setting (environment) | Effect |
|---|---|
| `QNXHOST_MODE=jit` | the default (set in `pwsh.props`): AOT images, the JIT for the rest |
| `QNXHOST_MODE=interp` | the interpreter only; slower, about the same memory |
| `QNXHOST_AOT_LOADER=dlopen` | load the AOT images with QNX's `dlopen` (commits them in full) |
| `QNXHOST_VERBOSE=1` | one line per AOT image the runtime maps or leaves to `dlopen` |
| `QNXHOST_MALLINFO=1` | malloc's statistics on standard error at exit |
| `QNXHOST_PRIVATE_TMPDIR=0` | keep the inherited `TMPDIR` behaviour (see below) |
| `TERMINFO` | defaults to `/usr/lib/terminfo`, where QNX keeps its terminfo |
| `SSL_CERT_FILE`, `SSL_CERT_DIR` | default to the install tree's `etc/ssl/cert.pem` and `etc/ssl/certs` |

Unless `TMPDIR` is set, the launcher sets it to `/tmp/qnxhost-<uid>`
(mode 0700, made if missing). .NET creates the Unix sockets of named pipes
in the temporary directory and deletes them when they close; on QNX 6.5,
deleting a socket's name while the network stack (io-pkt) serves another
socket request can hang io-pkt until a reboot. A directory of its own keeps
PowerShell's sockets away from other programs' activity in `/tmp`.

## What works

The PowerShell language and engine, the interactive prompt with PSReadLine
(editing, history, tab completion), the core cmdlets for objects, files and
formatting, modules, external programs and pipelines between them, child
processes and their exit codes, `Get-Process` and process information, named
and anonymous pipes, sockets, DNS, HTTP and HTTPS (`Invoke-WebRequest`,
`Invoke-RestMethod`), hashing and certificates, and JSON.

## Known limitations

- **No SSH remoting yet.** `libpsl-native`'s `ForkAndExecProcess`, which
  remoting uses to start `ssh`, returns "not supported".
- **PowerShell never acts as a login shell:** `pwsh.props` sets
  `__PWSH_LOGIN_CHECKED=1`, PowerShell's own marker that the check is done.
- **Process information** has no thread list (`Process.Threads` is empty),
  no handle counts, and peak memory values equal the current ones. It comes
  from QNX's `/proc` through System.Native, which presents the Linux files
  .NET reads.
- **Mount points are not enumerated**; the file system has one drive, `/`.
- **TCP/UDP statistics** (`System.Net.NetworkInformation`) are not supported.
- **File timestamps** set through a file descriptor have whole-second
  resolution.
- **Interrupted system calls are not restarted** on QNX 6.5. The launcher keeps
  asynchronous signals away from the runtime's threads; a program that
  signals a specific thread can still cause `EINTR` there.
- **Native debuggers** do not see the AOT images by name (the runtime maps
  them itself); `QNXHOST_AOT_LOADER=dlopen` restores that for debugging.
- **io-pkt and socket names:** the runtime serializes deleting Unix socket
  names against its own socket calls, and the private `TMPDIR` keeps its
  sockets apart, but another process deleting a socket name at the wrong
  moment can still hang QNX 6.5's network stack.
- 32-bit limits: a 4 GB address space.
