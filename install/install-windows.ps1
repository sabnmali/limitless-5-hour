<#
.SYNOPSIS
    Installs the No 5-Hour Limit scheduled task on Windows.

.DESCRIPTION
    Registers a Task Scheduler entry that pokes bin\keepalive.ps1 every few
    minutes. The script itself decides whether a ping is actually due, so the
    checks consume no AI usage when nothing is due, and resume after missed runs.

    No administrator rights are required: the task runs as the current user.

.PARAMETER CheckMinutes
    How often the scheduler wakes the script up. Default 15. Lower = less
    polling delay after a ping becomes due; provider window times are unverified.

.PARAMETER TaskName
    Name of the scheduled task. Default "No5HourLimit".

.PARAMETER EnableLocal
    Explicitly opt into laptop automation. Without this switch nothing is changed.
    Interactive CLI processes can briefly flash a console on some Windows systems.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install\install-windows.ps1 -EnableLocal
#>
[CmdletBinding()]
param(
    [int]    $CheckMinutes = 15,
    [string] $TaskName = 'No5HourLimit',
    [switch] $NoSkill,
    [switch] $EnableLocal
)

$ErrorActionPreference = 'Stop'

# A setup/helper invocation must not silently reactivate laptop automation.
if (-not $EnableLocal) {
    throw 'Local automation is opt-in. No changes made. Use -EnableLocal only if you want a laptop task; use install\disable-local-windows.ps1 to stop an existing task.'
}

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$Keepalive = Join-Path $RepoRoot 'bin\keepalive.ps1'
$ConfigDst = Join-Path $RepoRoot 'config.env'
$ConfigSrc = Join-Path $RepoRoot 'config.example.env'

function Write-Step($Message) { Write-Host "  -> $Message" }
function Write-Ok($Message)   { Write-Host "  OK  $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "  !   $Message" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  No 5-Hour Limit - Windows installer' -ForegroundColor Cyan
Write-Host '  ============================================================'
Write-Host ''

if (-not (Test-Path -LiteralPath $Keepalive)) {
    throw "Cannot find $Keepalive - run this script from inside the repository."
}

# --------------------------------------------------------------------------
# 1. Config file
# --------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigDst)) {
    Copy-Item -LiteralPath $ConfigSrc -Destination $ConfigDst
    Write-Ok "created config.env from the example"
} else {
    Write-Ok "config.env already exists - leaving it alone"
}

# --------------------------------------------------------------------------
# 2. Dependency check - and pin the absolute CLI paths into config.env
# --------------------------------------------------------------------------
# Task Scheduler runs with a different PATH than an interactive shell, so
# "claude" alone is often not resolvable there. Record the full path now.
function Set-ConfigValue {
    param([string] $Key, [string] $Value)
    $lines = @(Get-Content -LiteralPath $ConfigDst)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $found = $false
    $out = foreach ($l in $lines) {
        if ($l -match $pattern) { $found = $true; "$Key=$Value" } else { $l }
    }
    if (-not $found) { $out = @($out) + "$Key=$Value" }
    Set-Content -LiteralPath $ConfigDst -Value $out -Encoding UTF8
}

$claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($claudeCmd) {
    Set-ConfigValue -Key 'CLAUDE_BIN' -Value $claudeCmd.Source
    Write-Ok "claude CLI found: $($claudeCmd.Source)"
    $authRaw = ''
    try { $authRaw = (& $claudeCmd.Source auth status 2>&1 | Out-String) } catch { }
    if ($authRaw -match '"loggedIn"\s*:\s*true') {
        Write-Ok 'claude CLI is logged in'
    } else {
        Write-Warn 'claude CLI is NOT logged in. Run this once in a terminal:'
        Write-Host '        claude auth login' -ForegroundColor White
    }
} else {
    Write-Warn 'claude CLI not found on PATH. Install it with:'
    Write-Host '        npm install -g @anthropic-ai/claude-code' -ForegroundColor White
}

$codexCmd = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($codexCmd) {
    Set-ConfigValue -Key 'CODEX_BIN' -Value $codexCmd.Source
    Write-Ok "codex CLI found: $($codexCmd.Source)"
} else {
    Write-Step 'codex CLI not found (only needed if you enable CODEX_ENABLED)'
}

# --------------------------------------------------------------------------
# 3. Remember where we live + install the Claude Code skill
# --------------------------------------------------------------------------
$homeDir = [Environment]::GetFolderPath('UserProfile')
Set-Content -LiteralPath (Join-Path $homeDir '.no-5-hour-limit-path') -Value $RepoRoot -Encoding UTF8
Write-Ok 'recorded the install path in ~\.no-5-hour-limit-path'

if (-not $NoSkill) {
    $skillSrc = Join-Path $RepoRoot 'skill\no-5-hour-limit'
    $skillDst = Join-Path $homeDir '.claude\skills\no-5-hour-limit'
    if (Test-Path -LiteralPath $skillSrc) {
        New-Item -ItemType Directory -Path $skillDst -Force | Out-Null
        Copy-Item -Path (Join-Path $skillSrc '*') -Destination $skillDst -Recurse -Force
        Write-Ok 'Claude Code skill installed - just ask Claude "limitim ne durumda?"'
    }
}

# --------------------------------------------------------------------------
# 4. Register the scheduled task
# --------------------------------------------------------------------------
if ($CheckMinutes -lt 1)  { $CheckMinutes = 1 }
if ($CheckMinutes -gt 60) { $CheckMinutes = 60 }

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

$action = New-ScheduledTaskAction `
    -Execute $psExe `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Keepalive) `
    -WorkingDirectory $RepoRoot

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)

# New-ScheduledTaskTrigger cannot express "repeat forever" reliably across
# Windows versions, so set the repetition pattern explicitly.
try {
    $trigger.Repetition = New-CimInstance `
        -ClassName MSFT_TaskRepetitionPattern `
        -Namespace 'Root/Microsoft/Windows/TaskScheduler' `
        -ClientOnly `
        -Property @{
            Interval          = ('PT{0}M' -f $CheckMinutes)
            Duration          = ''       # empty string = indefinitely
            StopAtDurationEnd = $false
        }
} catch {
    Write-Warn "could not set an indefinite repetition pattern: $($_.Exception.Message)"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $CheckMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
}

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -Hidden

$settings.WakeToRun = $false
$settings.StartWhenAvailable = $false
$settings.DisallowStartIfOnBatteries = $true
$settings.StopIfGoingOnBatteries = $true

$principal = New-ScheduledTaskPrincipal `
    -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Optional local keepalive: requires an awake, signed-in computer on AC power; provider reset times are unverified.' `
    -Force | Out-Null

Write-Ok ("scheduled task '{0}' registered - checks every {1} minute(s)" -f $TaskName, $CheckMinutes)

# --------------------------------------------------------------------------
# 5. Verify end-to-end
# --------------------------------------------------------------------------
# The Task Scheduler service launches processes with a different environment -
# and, on some machines, a different view of the user profile - than an
# interactive shell. A CLI that resolves fine here can be invisible there, so
# actually run the task once and read what it wrote.
$script:Verified = $false
Write-Host ''
Write-Step 'verifying the task can reach the CLIs...'

$logFile = Join-Path $RepoRoot ("logs\keepalive-{0}.log" -f (Get-Date -Format 'yyyy-MM'))
$startedAt = Get-Date
$before = 0
if (Test-Path -LiteralPath $logFile) { $before = @(Get-Content -LiteralPath $logFile).Count }

Start-ScheduledTask -TaskName $TaskName
$deadline = (Get-Date).AddSeconds(60)
$newLines = @()
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $logFile) {
        $all = @(Get-Content -LiteralPath $logFile)
        if ($all.Count -gt $before) { $newLines = $all[$before..($all.Count - 1)] }
    }
    $taskNow = Get-ScheduledTask -TaskName $TaskName
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
    if ($taskNow.State -ne 'Running' -and $taskInfo.LastRunTime -ge $startedAt.AddSeconds(-2)) { break }
}

if ($taskNow.State -eq 'Running') {
    Write-Warn 'Verification still running; inspect Task Scheduler and the log when it finishes.'
} elseif ($taskInfo.LastTaskResult -ne 0) {
    Write-Warn "Task failed with exit $($taskInfo.LastTaskResult); check the log and CLI login."
} elseif ($newLines.Count -eq 0) {
    Write-Ok 'task completed without a new ping (not due or providers disabled); this does not verify CLI access'
} elseif ($newLines -match 'not found') {
    Write-Warn 'the scheduled task cannot see your CLI, even though this shell can.'
    Write-Host  '      Fix it with the CLI setup helper, then re-run this installer:' -ForegroundColor Yellow
    Write-Host  ('        powershell -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'setup-cli-windows.ps1')) -ForegroundColor White
    $newLines | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
} elseif ($newLines -match 'not logged in') {
    Write-Warn 'the task reached the CLI, but it is not logged in yet. Run:'
    Write-Host  '        claude auth login' -ForegroundColor White
} elseif ($newLines -match 'ERROR') {
    Write-Warn 'the task ran but reported an error:'
    $newLines | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
} elseif ($newLines -match 'quiet hours') {
    Write-Warn 'the task ran, but quiet hours are active so it did not ping.'
    Write-Host  '      Clear QUIET_HOURS in config.env to verify properly.' -ForegroundColor Yellow
} elseif ($newLines -match 'claude ok|codex ok') {
    # Only an actual success line counts. "No error in the log" is not the same
    # thing - a skipped run leaves no error either.
    Write-Ok 'verified - the scheduled task pinged successfully'
    $newLines | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    $script:Verified = $true
} else {
    Write-Warn 'the task ran but the outcome was unclear:'
    $newLines | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
}

# --------------------------------------------------------------------------
# 6. Done
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '  Installed.' -ForegroundColor Green
Write-Host ''
Write-Host '  Next steps'
Write-Host '  ----------'
if ($script:Verified) {
    # It already pinged during the check above; a second one would just spend
    # quota for nothing.
    Write-Host '   Nothing - the ping succeeded; future checks follow config.env.'
} else {
    Write-Host '   1. If the check above said "NOT logged in", run:  claude auth login'
    Write-Host '   2. Check status first; use -Force only if an immediate ping is needed:'
    Write-Host ('        powershell -ExecutionPolicy Bypass -File "{0}" -Force' -f $Keepalive)
}
Write-Host '   Check on it any time:'
Write-Host ('        powershell -ExecutionPolicy Bypass -File "{0}" -Status' -f $Keepalive)
Write-Host ''
Write-Host ('  To remove:  powershell -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'uninstall-windows.ps1'))
Write-Host ''
