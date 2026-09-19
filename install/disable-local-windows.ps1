<# Stop only this checkout's local task; keep credentials and configuration. #>
[CmdletBinding()]
param([string] $TaskName = 'No5HourLimit')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$expectedScript = Join-Path $repoRoot 'bin\keepalive.ps1'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Write-Output 'Local task is not installed.'; exit 0 }
if (@($task.Actions).Count -ne 1 -or $task.Actions.Arguments.IndexOf(('"{0}"' -f $expectedScript), [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'The task does not belong to this checkout. No change made.'
}
$stateDir = Join-Path $repoRoot 'state'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$backup = Join-Path $stateDir ('task-disabled-{0}.xml' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
Export-ScheduledTask -TaskName $TaskName | Set-Content -LiteralPath $backup -Encoding UTF8
Disable-ScheduledTask -TaskName $TaskName | Out-Null
Stop-ScheduledTask -TaskName $TaskName
$task = Get-ScheduledTask -TaskName $TaskName
$task.Settings.WakeToRun = $false
$task.Settings.StartWhenAvailable = $false
Set-ScheduledTask -TaskName $TaskName -Settings $task.Settings | Out-Null
Disable-ScheduledTask -TaskName $TaskName | Out-Null
$verified = Get-ScheduledTask -TaskName $TaskName
if ($verified.State -ne 'Disabled' -or $verified.Settings.WakeToRun) { throw 'Could not verify that local automation is disabled.' }
Write-Output 'Local task stopped and disabled; wake permission removed. Configuration and CLI logins preserved.'
