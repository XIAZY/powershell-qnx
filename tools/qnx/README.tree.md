# PowerShell 7.6.6 for QNX Neutrino 6.5.0 (x86)

This is an install tree of PowerShell 7.6.6 for QNX Neutrino 6.5.0 on 32-bit
x86, built from [XIAZY/powershell-qnx](https://github.com/XIAZY/powershell-qnx)
on the Mono runtime from
[XIAZY/dotnet-runtime-qnx](https://github.com/XIAZY/dotnet-runtime-qnx). It is
not an official PowerShell release.

## Install

As root, from the directory this file is in:

```sh
./install.sh                  # to /opt/powershell, with /usr/bin/pwsh
./install.sh --login-shell    # the same, and pwsh listed in /etc/shells
./install.sh --uninstall      # remove what install.sh made
```

`--prefix DIR` and `--bindir DIR` choose other places. Running `install.sh`
again replaces an earlier install; it never replaces a `pwsh` or a directory
it did not make. Without installing, the tree runs where it is:
`./pwsh/pwsh`.

## Run

```sh
pwsh                          # interactive
pwsh -Command 'Get-Date'      # one command
pwsh -File script.ps1
```

The first start after a boot, or after heavy disk activity, takes about
2.4 s, while the files are read from disk; later starts take under a second.

## Settings

`pwsh.props` sets these defaults; set the variable before starting
PowerShell to change one.

| Variable | Default | Change it to |
|---|---|---|
| `POWERSHELL_TELEMETRY_OPTOUT` | `1`: no telemetry is sent | `0` to send PowerShell's telemetry |
| `POWERSHELL_UPDATECHECK` | `Off` | `Default` to check for new releases at startup (they are not built for QNX) |
| `POWERSHELL_DIAGNOSTICS_OPTOUT` | `1`: other processes cannot attach to this PowerShell | `0` to allow `Enter-PSHostProcess`; see the documentation for the risk |
| `TZDIR` | the tree's `etc/zoneinfo` (IANA time zones) | another zoneinfo directory |
| `SSL_CERT_FILE`, `SSL_CERT_DIR` | the tree's `etc/ssl/cert.pem` and `etc/ssl/certs` | your own trust store |

## More

What works, what doesn't and why, SSH remoting, and how the port is put
together: [docs/qnx](https://github.com/XIAZY/powershell-qnx/blob/release/v7.6.6/docs/qnx/README.md).

PowerShell is licensed under the MIT License (`pwsh/LICENSE.txt`). This tree
was built against the QNX SDP 6.5.0, which is proprietary to BlackBerry QNX;
redistributing it is subject to your QNX licence.
