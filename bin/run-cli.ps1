# Execute a CLI in a disposable PowerShell job so a hung provider cannot
# prevent the other provider from running. Never expose captured CLI output.
# Returns output (stdout), errors (stderr) and code. They stay separate: a
# warning on stderr must not corrupt the JSON on stdout.
function Invoke-BoundedCli {
    param([string] $Executable, [string[]] $Arguments, [string] $Directory)
    $job = Start-Job -ScriptBlock {
        param($exe, $argv, $cwd)
        $ErrorActionPreference = 'Continue'
        # Reported first, so a timeout can stop this job's whole process tree.
        @{ hostPid = $PID }
        Set-Location -LiteralPath $cwd -ErrorAction Stop
        $LASTEXITCODE = 1
        $stdout = New-Object System.Collections.Generic.List[string]
        $stderr = New-Object System.Collections.Generic.List[string]
        & $exe @argv 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr.Add($_.ToString()) }
            else { $stdout.Add([string] $_) }
        }
        @{ output = ($stdout -join "`n"); errors = ($stderr -join "`n"); code = $LASTEXITCODE }
    } -ArgumentList $Executable, $Arguments, $Directory
    try {
        if (-not (Wait-Job $job -Timeout 120)) {
            # Stop-Job ends the job host but can leave the CLI it started
            # running. Kill the host's process tree first.
            $hostPid = Receive-Job $job -ErrorAction SilentlyContinue |
                Where-Object { $_ -is [hashtable] -and $_.ContainsKey('hostPid') } |
                Select-Object -First 1 | ForEach-Object { $_.hostPid }
            if ($hostPid -is [int] -and $hostPid -gt 0) {
                try {
                    $taskkill = $null
                    if ($env:SystemRoot) { $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe' }
                    # Windows only. pwsh elsewhere (tests; real runs there use
                    # keepalive.sh) blocks in Stop-Job if its job host is killed.
                    if ($taskkill -and (Test-Path -LiteralPath $taskkill)) { & $taskkill /T /F /PID $hostPid *> $null }
                } catch { }
            }
            return @{ output = ''; errors = ''; code = 124 }
        }
        $result = Receive-Job $job -ErrorAction SilentlyContinue |
            Where-Object { $_ -is [hashtable] -and $_.ContainsKey('code') } |
            Select-Object -Last 1
        if ($job.State -ne 'Completed' -or $null -eq $result) { return @{ output = ''; errors = ''; code = 1 } }
        return $result
    } finally {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}
