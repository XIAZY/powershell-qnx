# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
Describe "SSH Remoting API Tests" -Tags "Feature" {

    Context "SSHConnectionInfo Class Tests" {

        BeforeAll {
            ## Skip the test if ssh is not present.
            $skipTest = @(Get-Command 'ssh' -CommandType Application -ErrorAction SilentlyContinue).Count -eq 0
        }

        AfterEach {
            if ($null -ne $rs) {
                $rs.Dispose()
            }
        }

        It "SSHConnectionInfo constructor should throw null argument exception for null HostName parameter" {

            { [System.Management.Automation.Runspaces.SSHConnectionInfo]::new(
                "UserName",
                [System.Management.Automation.Internal.AutomationNull]::Value,
                [System.Management.Automation.Internal.AutomationNull]::Value,
                0) } | Should -Throw -ErrorId "PSArgumentNullException"
        }

        It "SSHConnectionInfo should throw file not found exception for invalid key file path" -Skip:$skipTest {
            $sshConnectionInfo = [System.Management.Automation.Runspaces.SSHConnectionInfo]::new(
                "UserName",
                "localhost",
                "NoValidKeyFilePath",
                22)

            $rs = [runspacefactory]::CreateRunspace($sshConnectionInfo)

            $e = { $rs.Open() } | Should -Throw -PassThru
            $e.Exception.InnerException.InnerException | Should -BeOfType System.IO.FileNotFoundException
        }

        It "SSHConnectionInfo should throw argument exception for invalid port (non 16bit uint)" {
            {
                $sshConnectionInfo = [System.Management.Automation.Runspaces.SSHConnectionInfo]::new(
                "UserName",
                "localhost",
                "ValidKeyFilePath",
                99999)

                $rs = [runspacefactory]::CreateRunspace($sshConnectionInfo)
                $rs.Open()
            } | Should -Throw -ErrorId "ArgumentException" -PassThru
        }
    }

    Context "SSH transport error handling" {

        BeforeAll {
            # A fake ssh that never reads its stdin and fails after a delay. When the client's first
            # message is larger than the stdin pipe, the client's write is still blocked when ssh exits.
            # That happens wherever pipes are smaller than the first message (about 5.4 KB): QNX's pipes
            # hold 5120 bytes, and Linux gives a user's new pipes a single page once
            # fs.pipe-user-pages-soft is exceeded.
            $fakeSshDir = Join-Path $TestDrive 'fakessh'
            $null = New-Item -ItemType Directory -Path $fakeSshDir
            $fakeSsh = Join-Path $fakeSshDir 'ssh'
            Set-Content -Path $fakeSsh -Value @(
                '#!/bin/sh'
                'sleep 3'
                'echo "ssh: connect to host localhost port 22: Connection refused" >&2'
                'exit 255'
            )
            if (-not $IsWindows) {
                chmod 755 $fakeSsh
            }

            $script = Join-Path $TestDrive 'open.ps1'
            Set-Content -Path $script -Value @'
try { Invoke-Command -HostName localhost -UserName UserName -ScriptBlock { 1 } -ErrorAction Stop; 'opened' }
catch { 'failed: ' + $_.Exception.Message }
'@
        }

        It "Invoke-Command reports an error when ssh fails after a delay" -Skip:$IsWindows {
            $oldPath = $env:PATH
            try {
                $env:PATH = $fakeSshDir + [System.IO.Path]::PathSeparator + $env:PATH
                $outFile = Join-Path $TestDrive 'out.txt'
                $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh') -ArgumentList '-NoProfile', '-NonInteractive', '-File', $script `
                    -RedirectStandardOutput $outFile -PassThru
            }
            finally {
                $env:PATH = $oldPath
            }

            $exited = $process.WaitForExit(60000)
            if (-not $exited) {
                $process.Kill()
            }

            $exited | Should -BeTrue -Because 'the client must not hang when ssh exits while a write to its stdin is blocked'
            Get-Content $outFile -Raw | Should -Match 'failed: '
        }
    }
}
