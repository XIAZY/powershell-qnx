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
- **Launcher:** `qnxhost`, from the runtime, replaces the `dotnet` host,
  which QNX cannot run. `pwsh/pwsh` is a copy of it: run under that name, it
  reads `pwsh.props` beside the `pwsh` directory (the trusted assemblies,
  search paths and runtime settings the `dotnet` host would pass), so that
  PowerShell is its own executable, as on Linux. It confines asynchronous
  signals to a thread of its own (QNX 6.5 cannot restart interrupted system
  calls), and starts the runtime on a thread with an 8 MiB stack.
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
0.7 s to exit, and about 2.4 s for the first start after a boot or after
heavy disk activity, when the libraries are read from disk; the interactive
prompt appears after about 1.2 s, and the process uses about 70 MB at the
prompt.

## Running

```sh
/opt/powershell/pwsh/pwsh                       # interactive
/opt/powershell/pwsh/pwsh -Command 'Get-Date'   # one command
/opt/powershell/pwsh/pwsh -File script.ps1
```

A symbolic link to `pwsh/pwsh` (in `/usr/bin`, for example) works too: the
launcher finds `pwsh.props` from its own resolved path, not from the name it
was started by. `pwsh -Login` and login shells (`-pwsh`) work.
`./bin/qnxhost pwsh.props [arguments]` is the same program, started through
the generic launcher.

| Setting (environment) | Effect |
|---|---|
| `QNXHOST_MODE=jit` | the default (set in `pwsh.props`): AOT images, the JIT for the rest |
| `QNXHOST_MODE=interp` | the interpreter only; slower, about the same memory |
| `QNXHOST_AOT_LOADER=dlopen` | load the AOT images with QNX's `dlopen` (commits them in full) |
| `QNXHOST_VERBOSE=1` | one line per AOT image the runtime maps or leaves to `dlopen` |
| `QNXHOST_MALLINFO=1` | malloc's statistics on standard error at exit |
| `POWERSHELL_DIAGNOSTICS_OPTOUT=0` | turn the host IPC listener back on (defaults to 1; see below) |
| `POWERSHELL_TELEMETRY_OPTOUT=0` | send PowerShell's telemetry (defaults to 1: off; see below) |
| `POWERSHELL_UPDATECHECK=Default` | check for new PowerShell releases at startup (defaults to `Off`) |
| `QNXHOST_PRIVATE_TMPDIR=0` | keep the inherited `TMPDIR` behaviour (see below) |
| `TERMINFO` | defaults to `/usr/lib/terminfo`, where QNX keeps its terminfo |
| `SSL_CERT_FILE`, `SSL_CERT_DIR` | default to the install tree's `etc/ssl/cert.pem` and `etc/ssl/certs` |
| `TZDIR` | defaults to the install tree's `etc/zoneinfo` (see below) |

Unless `TMPDIR` is set, the launcher sets it to `/tmp/qnxhost-<uid>`
(mode 0700, made if missing). .NET creates the Unix sockets of named pipes
in the temporary directory and deletes them when they close; on QNX 6.5,
deleting a socket's name while the network stack (io-pkt) serves another
socket request can hang io-pkt until a reboot. A directory of its own keeps
PowerShell's sockets away from other programs' activity in `/tmp`.

For the same reason `pwsh.props` sets `POWERSHELL_DIAGNOSTICS_OPTOUT=1`,
PowerShell's own switch for its host IPC listener: without it, every
PowerShell process creates a Unix socket at startup and deletes it at exit.
With it, ordinary use creates and deletes no socket name. The cost: other
processes cannot find or attach to this PowerShell (`Get-PSHostProcessInfo`,
`Enter-PSHostProcess`, `Debug-Runspace` across processes). Set it to 0
before starting PowerShell to get those back, and with them the exposure
described under the known limitations.

`pwsh.props` also turns off PowerShell's telemetry
(`POWERSHELL_TELEMETRY_OPTOUT=1`) and its check for new releases
(`POWERSHELL_UPDATECHECK=Off`): this is not an official PowerShell build, so
it reports nothing to Microsoft, and the releases the update check points to
are not built for QNX. Both are defaults, so setting the variables before
starting PowerShell turns them back on. Without the telemetry, each start is
also about 0.2 s faster.

Time zones: QNX has no time-zone database, so the install tree carries the
IANA zones (release 2026e) in `etc/zoneinfo`, and `TimeZoneInfo` finds them
by id (`America/Toronto`). QNX itself keeps the local zone in `TZ` as a
POSIX rule string (`EST5EDT4,M3.2.0/2,M11.1.0/2`), which .NET cannot read;
the launcher turns it into a zone .NET can find, leaving `TZ` unchanged for
QNX's own libc and for child programs. With `TZ` unset, the system's rule is
used. A zone name in `TZ` (`TZ=America/Toronto`) works in PowerShell but not
in QNX's libc, so other programs would see UTC.

## What works

The PowerShell language and engine, the interactive prompt with PSReadLine
(editing, history, tab completion), the core cmdlets for objects, files and
formatting, modules, external programs and pipelines between them, child
processes and their exit codes, `Get-Process` and process information, named
and anonymous pipes, sockets, DNS and reverse lookups, HTTP and HTTPS
(`Invoke-WebRequest`, `Invoke-RestMethod`), `Test-Connection` (as root
through a raw socket, otherwise through QNX's `ping`), hashing and
certificates, JSON, time zones, jobs, `FileSystemWatcher` and
`Get-Content -Wait` (by polling the directories), and SSH remoting (below).

## Changes to PowerShell itself

The port changes PowerShell's own code only where the fix is not specific to
QNX:

| Change | Effect |
|---|---|
| SSH remoting: `CloseConnection` ignores I/O errors from disposing the transport's streams | When ssh exits while the client's first write to its stdin is blocked on a full pipe, `Invoke-Command`, `New-PSSession` and `Enter-PSSession` report the SSH error instead of waiting forever. QNX's pipes (5120 bytes) are always smaller than that first message (about 5.4 KB); on Linux it happens with one-page pipes. Not submitted upstream. |
| `Format-List` and `Format-Table -Wrap` wrap at word boundaries in the invariant culture | In globalization-invariant mode (the only mode on QNX, and common in Linux containers) every culture's language is "iv", which was not in the list of languages that wrap at spaces, so long values broke mid-word. Not submitted upstream. |

## Known limitations

- **SSH remoting** works with QNX's own OpenSSH 5.2 (`Invoke-Command
  -HostName` from QNX to a QNX server; keys of type `ssh-rsa`). A QNX server
  needs `Subsystem powershell /opt/powershell/pwsh/pwsh -sshs -NoLogo` in its
  `sshd_config`. Interactive sessions (`Enter-PSSession`) are not verified
  yet.
- **Process information** has no thread list (`Process.Threads` is empty),
  no handle counts, and peak memory values equal the current ones. It comes
  from QNX's `/proc` through System.Native, which presents the Linux files
  .NET reads.
- **No locale data.** QNX 6.5 has no ICU, so .NET runs in
  globalization-invariant mode (`System.Globalization.Invariant=true` in
  `pwsh.props`). `pwsh.props` also sets
  `System.Globalization.PredefinedCulturesOnly=false`, so culture names such
  as `en-US` can be created (`Get-Help -UICulture`, `Update-Help`,
  `Save-Help`, scripts that name a culture) and behave like the invariant
  culture. Culture-specific date and number formats and the sorting rules of
  other languages are not available.
- **Mount points are not enumerated**; the file system has one drive, `/`.
- **TCP/UDP statistics** (`System.Net.NetworkInformation`) are not supported.
- **File timestamps** set through a file descriptor have whole-second
  resolution.
- **Interrupted system calls are not restarted** on QNX 6.5. The launcher keeps
  asynchronous signals away from the runtime's threads; a program that
  signals a specific thread can still cause `EINTR` there.
- **Native debuggers** do not see the AOT images by name (the runtime maps
  them itself); `QNXHOST_AOT_LOADER=dlopen` restores that for debugging.
- **io-pkt and socket names:** on QNX 6.5, deleting a Unix socket's name
  while io-pkt serves a socket request from any process can hang the
  network stack until a reboot. PowerShell itself deletes none in ordinary
  use (see `POWERSHELL_DIAGNOSTICS_OPTOUT` above), and the runtime keeps its
  own deletions apart from its own socket calls, but a script that disposes
  a `NamedPipeServerStream` or a `Socket` bound to a Unix socket path, or
  removes a socket file, while another process uses the network can still
  trigger it.
- 32-bit limits: a 4 GB address space.
