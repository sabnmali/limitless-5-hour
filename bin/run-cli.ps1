# Execute a CLI in a disposable PowerShell job so a hung provider cannot
# prevent the other provider from running. Never expose captured CLI output.
function Invoke-BoundedCli {
    param([string] $Executable, [string[]] $Arguments, [string] $Directory)
    $job = Start-Job -ScriptBlock {
        param($exe, $argv, $cwd)
        $ErrorActionPreference = 'Continue'
        Set-Location -LiteralPath $cwd -ErrorAction Stop
        $LASTEXITCODE = 1
        $output = & $exe @argv 2>&1 | Out-String
        @{ output = $output; code = $LASTEXITCODE }
    } -ArgumentList $Executable, $Arguments, $Directory
    try {
        if (-not (Wait-Job $job -Timeout 120)) { return @{ output = ''; code = 124 } }
        $result = Receive-Job $job -ErrorAction SilentlyContinue
        if ($job.State -ne 'Completed' -or $null -eq $result) { return @{ output = ''; code = 1 } }
        return $result
    } finally {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}
