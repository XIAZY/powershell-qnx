# PowerShell on QNX Neutrino 6.5.0 (x86) and BlackBerry 10 (ARM)

PowerShell 7.6 runs on QNX Neutrino 6.5.0 on 32-bit x86, and on BlackBerry
10 (QNX on 32-bit ARMv7; see [BlackBerry 10](#blackberry-10)). This page
describes how it is put together, how to run it, and what does and does not
work. To
build it, see [docs/building/qnx.md](../building/qnx.md).

The QNX SDP 6.5.0 headers and libraries the build links against are
proprietary to BlackBerry QNX: they are not distributed with this repository
or its releases, and you need your own licensed copy to build.

## How it works

- **Runtime:** Mono, from the QNX port of dotnet/runtime
  ([XIAZY/dotnet-runtime-qnx](https://github.com/XIAZY/dotnet-runtime-qnx)),
  branch `release/10.0`. The port adds QNX as a host for Mono and System.Native;
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
in the temporary directory and deletes them when they close, and on QNX 6.5
deleting a socket's name can hang the network stack (io-pkt) until a reboot
(see [Deleting Unix socket names](#deleting-unix-socket-names)). A directory
of its own keeps PowerShell's sockets away from other programs' activity in
`/tmp`.

For the same reason `pwsh.props` sets `POWERSHELL_DIAGNOSTICS_OPTOUT=1`,
PowerShell's own switch for its host IPC listener: without it, every
PowerShell process creates a Unix socket at startup and deletes it at exit.
With it, ordinary use creates and deletes no socket name. The cost: other
processes cannot find or attach to this PowerShell (`Get-PSHostProcessInfo`,
`Enter-PSHostProcess`, `Debug-Runspace` across processes). Set it to 0
before starting PowerShell to get those back, and with them the exposure
described under [Deleting Unix socket names](#deleting-unix-socket-names).

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

### SSH remoting

PowerShell remoting over SSH works with QNX's own OpenSSH 5.2, as a client
and as a server: `Invoke-Command -HostName`, `New-PSSession` (a session keeps
its state across commands), interactive `Enter-PSSession`, and
`Copy-Item -ToSession` and `-FromSession`, between QNX machines and with
PowerShell on Linux in both directions. Keys must be of type `ssh-rsa`.

A QNX server needs the `powershell` subsystem in its `sshd_config`:

```
Subsystem powershell /opt/powershell/pwsh/pwsh -sshs -NoLogo
```

Current OpenSSH releases disable the algorithms OpenSSH 5.2 uses, so the
other side must allow them:

- a Linux client connecting to QNX: RSA host keys and RSA signatures, for
  example `-Options @{ HostKeyAlgorithms = '+ssh-rsa'; PubkeyAcceptedAlgorithms = '+ssh-rsa' }`
  with `Invoke-Command`, `New-PSSession` or `Enter-PSSession`, or the same
  settings in `~/.ssh/config`;
- a Linux server that QNX connects to: in its `sshd_config`,

  ```
  HostKeyAlgorithms +ssh-rsa
  PubkeyAcceptedAlgorithms +ssh-rsa
  KexAlgorithms +diffie-hellman-group14-sha1
  ```

## What doesn't work, and why

Most of PowerShell works on QNX as it does on Linux. This table lists what
differs, as measured on QNX 6.5.0 with this build, why, and what to use
instead. "As on Linux" marks behaviour that looks like a QNX problem but is
the same with Microsoft's Linux build.

| Feature | On QNX | Why | Instead |
|---|---|---|---|
| Culture-specific formats, sorting and casing, time-zone display names | Every culture behaves like the invariant culture: `de-DE` formats a date as `10/01/2026 13:05:00` and 1234.5 as `1,234.50`; `'i'.ToUpper('tr-TR')` is `I`; `Europe/Paris` is displayed as `(UTC+01:00) Europe/Paris`. Culture names such as `en-US` can be created (`Get-Help -UICulture`, `Update-Help`) | QNX 6.5 has no ICU, so .NET runs in globalization-invariant mode (`System.Globalization.Invariant=true` and `System.Globalization.PredefinedCulturesOnly=false` in `pwsh.props`) | Explicit formats (`Get-Date -Format yyyy-MM-dd`) and ordinal comparisons |
| Attaching to another PowerShell (`Get-PSHostProcessInfo`, `Enter-PSHostProcess`, `Debug-Runspace` across processes) | Off by default: `Get-PSHostProcessInfo` finds no PowerShell | Each PowerShell would create a Unix socket at startup and delete it at exit, and deleting a socket's name can hang QNX 6.5's network stack (see [Deleting Unix socket names](#deleting-unix-socket-names)), so `pwsh.props` sets `POWERSHELL_DIAGNOSTICS_OPTOUT=1` | Start the PowerShell you want to attach to with `POWERSHELL_DIAGNOSTICS_OPTOUT=0`, accepting that risk for that process |
| Deleting a Unix socket's name (named pipes, Unix sockets, socket files) | Can hang the network stack until a reboot | A QNX 6.5 io-pkt bug; PowerShell itself deletes none in ordinary use | See [Deleting Unix socket names](#deleting-unix-socket-names): anonymous pipes or loopback TCP in scripts, and no `-CustomPipeName` leftovers removed except right after a reboot |
| IPv6 | Not available: `[Net.Sockets.Socket]::OSSupportsIPv6` is false, and .NET uses IPv4. `localhost` works | QNX 6.5's IPv4 network stack (`io-pkt-v4-hc`) has no IPv6: `socket(AF_INET6)` fails with `EAFNOSUPPORT`. The IPv6 stack (`io-pkt-v6-hc`) has not been tested | IPv4 addresses |
| `Publish-Module`, `Publish-Script` | Fail: "dotnet command version '2.0.0' or newer is required" | PowerShellGet 2 packs modules with the .NET SDK's `dotnet` command, which does not run on QNX | `Publish-PSResource` |
| `Find-PackageProvider NuGet`, `Install-PackageProvider NuGet` | "No match was found": **as on Linux** | In PowerShell 7 the NuGet provider ships with PackageManagement (`Get-PackageProvider` lists it), so there is nothing to install | Nothing: the provider is already there |
| `Test-Connection -Traceroute`: the address of each hop | Each hop is reported with the destination's address (`Hostname`, `Reply.Address`); hop numbers and statuses are right | As with .NET on FreeBSD and macOS: on Linux, .NET gets routers' addresses from `IP_RECVERR`, which QNX does not have | `/usr/bin/traceroute` |
| `Test-Connection` without root: `-MtuSize`, `-BufferSize`, `-TimeToLive` | `-MtuSize` and `-BufferSize` fail ("Unable to send custom ping payload"); with `-TimeToLive`, an expired TTL is reported as `TimedOut`. Plain pings work | Raw ICMP sockets need root, and QNX has no unprivileged ICMP sockets, so .NET runs the `ping` utility instead, which cannot send a custom payload | Run as root: .NET then uses a raw socket, and all of these work, `-Traceroute` included |
| `FileSystemWatcher`, `Get-Content -Wait` | Work, by polling: events arrive up to 250 ms late (measured 5 to 257 ms), longer for large watched trees; several changes to one file within that interval arrive as one; a rewrite that keeps both size and modification time is not seen; no access events | QNX 6.5 has no inotify; the runtime emulates it by scanning the watched directories, at about 300 `lstat` calls a second at most | Don't rely on seeing every intermediate change |
| Start time after a boot | About 2.4 s for the first start after a boot or heavy disk activity, against under 1 s when the files are cached | A cold start reads its pages from disk one page fault at a time; reading the whole working set first was measured to be slower | Nothing: later starts are fast |
| Typing at the interactive prompt from some terminals | With some ssh clients the line being edited is drawn wrongly as you type, Backspace included | QNX 6.5's terminal database has only a few entries (`xterm` among them, no `xterm-256color`), and the line editor depends on the terminal type the client announces | Start PowerShell with `TERM=xterm pwsh`, or `export TERM=xterm` first |
| Many processes started while the disk is being flushed, on two or more CPUs | On a KVM-based cloud VM with 2 vCPUs, the whole machine froze until a power cycle: four parallel ssh login loops beside a file write and `sync` every 2 s did it in both runs, within minutes, with no PowerShell running (the cleanly measured run showed both vCPUs at 100% and no I/O) | QNX 6.5's SMP kernel (`procnto-smp-instr`); the uniprocessor kernel ran the same load. It did not appear in two runs of the same load under QEMU's full emulation (2 CPUs, the same kernel with a patched local-APIC startup that QEMU requires; that APIC startup does not boot on the KVM VM), so it depends on the virtual machine; real SMP hardware and other hypervisors have not been tested | Boot the uniprocessor image (`qnxbasedma.ifs`, in QNX 6.5's stock install, selectable at the boot menu) or give the VM one vCPU |
| Files over 2 GB | Work: writing, reading and seeking past 2 GiB and `SetLength(3GB)` | | Note that QNX's `qnx6` file system has no sparse files: `SetLength(3GB)` allocates 3 GB on disk |
| Listing mount points | `[IO.DriveInfo]::GetDrives()` returns `/` only, and `Get-PSDrive` shows `/` and `Temp`, whatever else is mounted | QNX 6.5 has no API that lists mounts; the runtime reports the root | `df` |
| Process details (`Get-Process`) | `Threads` is empty, `HandleCount` is 0, and peak memory values equal the current ones | .NET reads Linux's `/proc` files; the runtime presents them from QNX's process manager, which has no counterpart for these | `pidin` |
| Network statistics (`System.Net.NetworkInformation`: IP, TCP and UDP statistics, active connections and listeners) | Throw `NetworkInformationException`. Gateway addresses work (IPv4) | .NET reads them from Linux's `/proc/net` files, which QNX does not have | `netstat` |
| A zone name in `TZ` (`TZ=America/Toronto`) | Works in PowerShell, but QNX's own programs (`date`) then show UTC | QNX's libc understands only POSIX rule strings | A rule string (`EST5EDT4,M3.2.0/2,M11.1.0/2`), which both understand |
| `[TimeZoneInfo]::FindSystemTimeZoneById([TimeZoneInfo]::Local.Id)` with a rule string in `TZ` | Throws `TimeZoneNotFoundException` | Lookups by id reject the rule's `,` and `<` characters | `[TimeZoneInfo]::Local` |
| SSH remoting | Works: `Invoke-Command -HostName`, `New-PSSession`, interactive `Enter-PSSession` and `Copy-Item -ToSession`/`-FromSession`, between QNX machines and with Linux in both directions | | A modern OpenSSH needs older algorithms enabled to talk to QNX's OpenSSH 5.2: see [SSH remoting](#ssh-remoting) |
| Type checks of PowerShell classes | Some invalid definitions are accepted: `class C : System.IComparable { }` loads, where Linux reports that `CompareTo` has no implementation. A few error messages differ, and more assemblies load at startup | The runtime is Mono, not CoreCLR, which does not run on QNX | Nothing: a correct script gets the same result |
| File times | Whole seconds | QNX 6.5 keeps file times in whole seconds | |

Two more things to know: native debuggers do not see the ahead-of-time
compiled libraries by name, because the runtime maps them itself instead of
with `dlopen` (set `QNXHOST_AOT_LOADER=dlopen` while debugging); and the
process has a 32-bit, 4 GB address space.

### Deleting Unix socket names

On QNX 6.5, deleting the name of a Unix-domain socket (its file) can hang
the network stack, io-pkt, until a reboot: every socket call then blocks,
and ssh and the network stop answering. Measurements by the QNX port of Go
(QNX 6.5.0, two CPUs) found that a single program deleting names in a tight
loop, with nothing else using the network, is enough. After the socket was
closed, the hang came somewhere between hundreds and tens of thousands of
deletions; while the socket was still open it was rarer, but it was seen.
Deleting a name while another socket call is in progress is an older, more
frequent form of the same hang. Sockets without names (`socketpair`, unbound
sockets) were not affected.

What this build does about it:
- **PowerShell deletes no socket names in ordinary use.** Its host IPC
  listener is off by default (`POWERSHELL_DIAGNOSTICS_OPTOUT=1`), so no name
  is created in the first place. Jobs, child processes, external commands,
  SSH remoting and the web cmdlets use pipes and TCP, which have no names.
- **The runtime keeps its own deletions apart from socket calls**, within
  each process and across the processes of one user that run on it. That
  covers only the older form; it cannot make a deletion itself safe.

What can still delete names, and how to avoid it:
- **`pwsh -CustomPipeName` (and `-NamedPipeServerMode`)** creates a named
  pipe and leaves its socket file behind at exit. This is the one way
  ordinary use creates the hazard: the files are harmless until something
  deletes them. Remove leftover socket files only right after a reboot,
  when io-pkt holds no names.
- **Scripts** that dispose a `NamedPipeServerStream` or a `Socket` bound to a
  Unix socket path, or that `Remove-Item` a socket file, delete a name.
  Prefer anonymous pipes or loopback TCP. If a name must be deleted, delete
  it while the socket is still open (`NamedPipeServerStream` already does);
  this makes the hang rarer, not impossible.

## BlackBerry 10

PowerShell also runs on BlackBerry 10, BlackBerry's QNX on 32-bit ARMv7,
with the same runtime port built for ARM (`-os qnx -arch arm`) and .NET's
linux-arm managed libraries. Everything above applies, except as listed
here. The measurements are from a BlackBerry 10 phone (4 Krait cores at
2.26 GHz).

- **Starting:** `pwsh -Command '$PSVersionTable'` takes about 4.4 s from
  process start to the first command, with the sixteen libraries compiled
  ahead of time (about 15.6 s with the JIT alone). The images take about
  38 MB on disk; only the pages used take memory.
- **Where it can run:** not from the SD card, which is mounted without
  execute permission: the install tree, or at least its programs, native
  libraries and AOT images, must be on internal storage. Assemblies can be
  read from the card.

| Feature | On BlackBerry 10 | Why | Instead |
|---|---|---|---|
| IPv6 | Works, with dual-mode sockets | BlackBerry 10's network stack has IPv6 | |
| `FileSystemWatcher`, `Get-Content -Wait` | Work with the system's inotify: no polling delay | BlackBerry 10's libc has inotify | |
| Time zone | The system's zone (an IANA name such as `Europe/Amsterdam`) is used when `TZ` is unset; a zone name in `TZ` also works for the system's own programs | BlackBerry 10's libc reads zone names | |
| `Get-Process` | Lists only the user's own processes | A process that is not root cannot read other processes' details (`/proc/<pid>/as` is root-only); `pidin` shows the same | — (a platform restriction) |
| `Process.Modules` after an upgrade | The names of loaded modules other than the main module can show a deleted file's path until a reboot; the main module, `$PSHOME` and the process path are right | The process manager keeps names cached for reused files | Reboot after upgrading |
| Starting right after an upgrade in place | If `pwsh` itself fails to start right after its files were replaced, a reboot fixes it; the runtime guards the libraries and assemblies it loads | BlackBerry 10 can run or map a newly written file with the cached contents of a deleted one (see the runtime's QNX design note) | Reboot |
| `Test-Connection`, `System.Net.NetworkInformation.Ping` | Fail with `PingException` | Without root, .NET runs the system's `ping`, which ordinary users cannot execute on BlackBerry 10, and PowerShell cannot run as root there (root's loader refuses programs from outside the system) | `Test-Connection <host> -TcpPort <port>`, which connects over TCP |
| Tests and scripts that use `id`, `/usr/bin/ping` | Fail: not available to ordinary users, or not installed | BlackBerry 10 has a reduced set of system programs | `[Environment]::UserName`, the .NET APIs |
| SSH remoting | Not available as a client | BlackBerry 10 has no `ssh` client, which SSH remoting runs; the PowerShell side is the same as on QNX 6.5, where it works | An `ssh` client installed separately |

## Changes to PowerShell itself

The port changes PowerShell's own code only where the fix is not specific to
QNX:

| Change | Effect |
|---|---|
| SSH remoting: `CloseConnection` ignores I/O errors from disposing the transport's streams | When ssh exits while the client's first write to its stdin is blocked on a full pipe, `Invoke-Command`, `New-PSSession` and `Enter-PSSession` report the SSH error instead of waiting forever. QNX's pipes (5120 bytes) are always smaller than that first message (about 5.4 KB); on Linux it happens with one-page pipes. Not submitted upstream. |
| `Format-List` and `Format-Table -Wrap` wrap at word boundaries in the invariant culture | In globalization-invariant mode (the only mode on QNX, and common in Linux containers) every culture's language is "iv", which was not in the list of languages that wrap at spaces, so long values broke mid-word. Not submitted upstream. |
