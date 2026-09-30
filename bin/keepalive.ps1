<#
.SYNOPSIS
    No 5-Hour Limit - keeps AI CLI usage windows rolling.

.DESCRIPTION
    Sends a minimal "ping" prompt to the Claude CLI and/or the Codex CLI once
    the configured interval has elapsed since the last successful ping. That
    may start an idle usage window. Reported window ends are estimates, not
    actual provider reset times. Every ping consumes subscription usage.

    The script is idempotent. It only pings when the interval has actually
    elapsed, so the scheduler just needs to poke it every few minutes.

.PARAMETER Status
    Print current state (last ping, window end, next ping due) and exit.

.PARAMETER Force
    Ping now, ignoring the interval and quiet hours.

.PARAMETER DryRun
    Show what would be run without calling any CLI.

.PARAMETER ConfigPath
    Path to a config file. Defaults to <repo>/config.env.

.EXAMPLE
    powershell -File bin\keepalive.ps1 -Status
#>
[CmdletBinding()]
param(
    [switch] $Status,
    [switch] $Force,
    [switch] $DryRun,
    [string] $ConfigPath
)

# Native CLIs write progress to stderr; 'Stop' would turn that into a crash.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'run-cli.ps1')

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$LogDir    = Join-Path $RepoRoot 'logs'
$StateDir  = Join-Path $RepoRoot 'state'
$StateFile = Join-Path $StateDir 'state.json'
$WorkDir   = Join-Path $StateDir 'workdir'

foreach ($d in @($LogDir, $StateDir, $WorkDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config.env' }

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
$Config = @{
    INTERVAL_MINUTES       = '301'
    CLAUDE_ENABLED         = 'true'
    CLAUDE_MODEL           = 'haiku'
    CLAUDE_PROMPT          = 'ok'
    CLAUDE_BIN             = ''
    CODEX_ENABLED          = 'false'
    CODEX_MODEL            = ''
    CODEX_PROMPT           = 'ok'
    CODEX_BIN              = ''
    CODEX_REASONING_EFFORT = 'low'
    LOG_RETENTION_DAYS     = '30'
    QUIET_HOURS            = ''
}

# A config path given on the command line has to exist. Falling back to the
# defaults there would silently enable Claude against the caller's intent.
if ($PSBoundParameters.ContainsKey('ConfigPath') -and -not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "config file not found: $ConfigPath" -ForegroundColor Red
    exit 2
}

if (Test-Path -LiteralPath $ConfigPath) {
    foreach ($line in (Get-Content -LiteralPath $ConfigPath)) {
        # Windows PowerShell writes UTF-8 with a BOM, which would otherwise
        # hide the '#' that marks the first line as a comment.
        $trimmed = $line.TrimStart([char]0xFEFF).Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $trimmed.Substring(0, $idx).Trim()
        $val = $trimmed.Substring($idx + 1).Trim().Trim('"').Trim("'")
        # $Config was seeded above with every key this script understands, so
        # this doubles as an allowlist: an unknown key is ignored rather than
        # smuggled in.
        if ($Config.ContainsKey($key)) { $Config[$key] = $val }
    }
}

function Get-Cfg([string] $Key) {
    if ($Config.ContainsKey($Key)) { return [string] $Config[$Key] }
    return ''
}

function Get-CfgBool([string] $Key) {
    return ((Get-Cfg $Key) -match '^(?i:true|1|yes|on)$')
}

$IntervalMinutes = 301
$parsed = 0
if ([int]::TryParse((Get-Cfg 'INTERVAL_MINUTES'), [ref] $parsed) -and $parsed -ge 1) {
    $IntervalMinutes = $parsed
}
# Reject intervals that would repeatedly consume quota inside the same window.
if ($IntervalMinutes -lt 300) { $IntervalMinutes = 300 }
if ($IntervalMinutes -gt 525600) { $IntervalMinutes = 525600 }

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
$LogFile = Join-Path $LogDir ("keepalive-{0}.log" -f (Get-Date -Format 'yyyy-MM'))

function Protect-Secrets {
    # Error text can quote a credential back at us. Mask anything token-shaped
    # before it reaches a log file or a screen.
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return ([regex]::Replace($Text, '[A-Za-z0-9_-]{24,}', '[redacted]'))
}

function Write-Log {
    param([string] $Level, [string] $Message)
    $Message = Protect-Secrets $Message
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    $line = "[{0}] {1,-5} {2}" -f $stamp, $Level.ToUpperInvariant(), $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    if ($Level -eq 'error') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'warn') { Write-Host $line -ForegroundColor Yellow }
    else { Write-Host $line }
}

function Remove-OldLogs {
    $days = 0
    if (-not [int]::TryParse((Get-Cfg 'LOG_RETENTION_DAYS'), [ref] $days)) { return }
    if ($days -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$days)
    Get-ChildItem -LiteralPath $LogDir -Filter 'keepalive-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------
function Read-State {
    $result = @{}
    if (-not (Test-Path -LiteralPath $StateFile)) { return $result }
    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $result }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in $obj.PSObject.Properties) { $result[$p.Name] = $p.Value }
    } catch { }
    return $result
}

function Write-State($State) {
    # Write beside the real file and rename it into place, so an interrupted
    # run cannot leave half a state behind. A failure here has to be loud: a
    # lost timestamp means the next run pings again for nothing.
    $tmp = "$StateFile.tmp.$PID"
    try {
        ($State | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        if ([System.IO.File]::Exists($StateFile)) {
            # PowerShell 5.1 marshals $null to an empty string here, which is
            # not a valid backup path. Use an explicit temporary backup.
            $backup = "$StateFile.bak.$PID"
            [System.IO.File]::Replace($tmp, $StateFile, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($tmp, $StateFile)
        }
        return $true
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Log 'error' "could not write state file: $($_.Exception.Message)"
        return $false
    }
}

function Get-LastPingUtc($State, [string] $Provider) {
    if (-not $State.ContainsKey($Provider)) { return $null }
    $entry = $State[$Provider]
    if ($null -eq $entry) { return $null }

    $value = $null
    if ($entry -is [System.Collections.IDictionary]) {
        $value = $entry['lastSuccessUtc']
    } elseif ($entry.PSObject.Properties.Name -contains 'lastSuccessUtc') {
        $value = $entry.lastSuccessUtc
    }
    # PowerShell 7's ConvertFrom-Json already turns ISO strings into dates.
    if ($value -is [datetime]) { return $value.ToUniversalTime() }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    try {
        return [datetime]::Parse(
            $value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
}

function Get-RetryUtc($State, [string] $Provider) {
    # Set when the provider's quota ran out; no ping is attempted before it.
    if (-not $State.ContainsKey($Provider) -or $null -eq $State[$Provider]) { return $null }
    $entry = $State[$Provider]
    $value = $null
    if ($entry -is [System.Collections.IDictionary]) { $value = $entry['retryAfterUtc'] }
    elseif ($entry.PSObject.Properties.Name -contains 'retryAfterUtc') { $value = $entry.retryAfterUtc }
    # PowerShell 7's ConvertFrom-Json already turns ISO strings into dates.
    if ($value -is [datetime]) { return $value.ToUniversalTime() }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    try {
        return [datetime]::Parse(
            $value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
}

function Get-FailureCount($State, [string] $Provider) {
    # Consecutive failed attempts; drives the failure backoff.
    if (-not $State.ContainsKey($Provider) -or $null -eq $State[$Provider]) { return 0 }
    $entry = $State[$Provider]
    $value = $null
    if ($entry -is [System.Collections.IDictionary]) { $value = $entry['failures'] }
    elseif ($entry.PSObject.Properties.Name -contains 'failures') { $value = $entry.failures }
    $n = 0
    if (-not [int]::TryParse([string] $value, [ref] $n) -or $n -lt 0) { return 0 }
    return [math]::Min($n, 100)
}

function Get-FailureRetryUtc([int] $Failures) {
    # 30 min, 1 h, 2 h, 4 h, then 6 h, matching keepalive.sh. A broken login or
    # CLI is not relaunched every poll; -Force still pings at once.
    $minutes = 30
    for ($i = 1; $i -lt $Failures -and $minutes -lt 360; $i++) { $minutes *= 2 }
    return [datetime]::UtcNow.AddMinutes([math]::Min($minutes, 360))
}

function Set-ProviderEntry($State, [string] $Provider, [hashtable] $Values) {
    # ConvertFrom-Json gives PSCustomObjects; rebuild as a hashtable so the
    # other field of the entry survives the update.
    $entry = @{}
    $old = $State[$Provider]
    if ($old -is [System.Collections.IDictionary]) { foreach ($k in $old.Keys) { $entry[$k] = $old[$k] } }
    elseif ($null -ne $old) { foreach ($p in $old.PSObject.Properties) { $entry[$p.Name] = $p.Value } }
    foreach ($k in $Values.Keys) {
        if ($null -eq $Values[$k]) { $entry.Remove($k) } else { $entry[$k] = $Values[$k] }
    }
    $State[$Provider] = $entry
}

# Raw CLI output is only ever matched here, never printed or logged.
function Test-QuotaExhausted([string] $Text) {
    # Only the subscription-quota wording, matching keepalive.sh. Generic words
    # such as "quota" or "429" also appear in unrelated faults.
    return ($Text -match '(?i)usage[_ -]?limit|hit your[^.]{0,30}limit|(weekly|5-hour|five-hour|session|opus|sonnet) limit|limit reached')
}

function Get-QuotaRetryUtc([string] $Text) {
    # Codex says "... try again in 2 days 3 hours 5 minutes". Only digits are
    # taken from that text; anything unreadable falls back to one hour. Clamped
    # to [30 minutes, 7 days], matching keepalive.sh.
    $minutes = 0
    $hint = [regex]::Match(($Text -replace '\r?\n', ' '), '(?i)try again in[^.]{0,80}').Value
    if ($hint) {
        $d = [regex]::Match($hint, '(?i)(\d{1,4}) *days?')
        $h = [regex]::Match($hint, '(?i)(\d{1,4}) *(hours?|hrs?)')
        $m = [regex]::Match($hint, '(?i)(\d{1,5}) *(minutes?|mins?)')
        if ($d.Success) { $minutes += [int] $d.Groups[1].Value * 1440 }
        if ($h.Success) { $minutes += [int] $h.Groups[1].Value * 60 }
        if ($m.Success) { $minutes += [int] $m.Groups[1].Value }
    }
    if ($minutes -le 0) { $minutes = 60 }
    if ($minutes -lt 30) { $minutes = 30 }
    if ($minutes -gt 10080) { $minutes = 10080 }
    return [datetime]::UtcNow.AddMinutes($minutes)
}

# --------------------------------------------------------------------------
# Quiet hours
# --------------------------------------------------------------------------
function Test-QuietHours {
    $spec = Get-Cfg 'QUIET_HOURS'
    if ([string]::IsNullOrWhiteSpace($spec)) { return $false }
    if ($spec -notmatch '^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$') { return $false }
    $sh = [int] $Matches[1]; $sm = [int] $Matches[2]
    $eh = [int] $Matches[3]; $em = [int] $Matches[4]
    # Without this, a range like 00:00-99:00 would silence the whole day.
    if ($sh -gt 23 -or $eh -gt 23 -or $sm -gt 59 -or $em -gt 59) { return $false }
    $start = $sh * 60 + $sm
    $end   = $eh * 60 + $em
    $clock = Get-Date   # one read: two could straddle an hour rollover
    $nowM  = $clock.Hour * 60 + $clock.Minute
    if ($start -le $end) { return ($nowM -ge $start -and $nowM -lt $end) }
    return ($nowM -ge $start -or $nowM -lt $end)   # range crosses midnight
}

# --------------------------------------------------------------------------
# Providers
# --------------------------------------------------------------------------
function Resolve-Cli([string] $Name) {
    # 1. An explicit path from config.env always wins. Task Scheduler runs with
    #    a different PATH than an interactive shell, so this is the reliable
    #    route and the installer fills it in.
    $configured = Get-Cfg ('{0}_BIN' -f $Name.ToUpperInvariant())
    if ((-not [string]::IsNullOrWhiteSpace($configured)) -and (Test-Path -LiteralPath $configured)) {
        return $configured
    }

    # 2. PATH.
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    # 3. The usual install locations.
    $candidates = @(
        (Join-Path $env:APPDATA          ('npm\{0}.cmd'  -f $Name)),
        (Join-Path $env:APPDATA          ('npm\{0}.ps1'  -f $Name)),
        (Join-Path $env:LOCALAPPDATA     ('{0}\bin\{0}.exe' -f $Name)),
        (Join-Path $env:USERPROFILE      ('bin\{0}.cmd'  -f $Name)),
        (Join-Path $env:USERPROFILE      ('bin\{0}.exe'  -f $Name)),
        (Join-Path $env:USERPROFILE      ('.local\bin\{0}.exe' -f $Name)),
        (Join-Path $env:ProgramFiles     ('nodejs\{0}.cmd' -f $Name))
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    return $null
}

function Invoke-ClaudePing {
    if ($env:ANTHROPIC_API_KEY -or $env:ANTHROPIC_AUTH_TOKEN -or
        $env:CLAUDE_CODE_USE_BEDROCK -eq '1' -or $env:CLAUDE_CODE_USE_VERTEX -eq '1' -or $env:CLAUDE_CODE_USE_FOUNDRY -eq '1') {
        return @{ ok = $false; message = 'API/provider credentials detected; use subscription login in a clean environment' }
    }
    $exe = Resolve-Cli 'claude'
    if (-not $exe) {
        return @{ ok = $false; message = 'claude CLI not found - set CLAUDE_BIN in config.env, or run install\setup-cli-windows.ps1' }
    }

    $cliArgs = @(
        '-p', (Get-Cfg 'CLAUDE_PROMPT'),
        '--model', (Get-Cfg 'CLAUDE_MODEL'),
        '--system-prompt', 'Reply with exactly: ok',
        '--restricted', '--safe-mode', '--tools=',
        '--strict-mcp-config',
        '--no-session-persistence',
        '--permission-mode', 'dontAsk',
        '--output-format', 'json'
    )

    if ($DryRun) { return @{ ok = $true; message = "DRY RUN: claude $($cliArgs -join ' ')" } }

    $invocation = Invoke-BoundedCli $exe $cliArgs $WorkDir
    # Match wording on everything, but parse JSON from stdout only: a warning
    # on stderr must not turn a good ping into a failure.
    $raw = ($invocation.output, $invocation.errors) -join "`n"

    $json = $null
    try { $json = $invocation.output | ConvertFrom-Json -ErrorAction Stop } catch {
        $lastObject = @(([string] $invocation.output) -split '\r?\n' | Where-Object { $_.TrimStart().StartsWith('{') })
        if ($lastObject.Count -gt 0) {
            try { $json = $lastObject[-1] | ConvertFrom-Json -ErrorAction Stop } catch { }
        }
    }

    if ($invocation.code -ne 124 -and (Test-QuotaExhausted $raw) -and
        ($invocation.code -ne 0 -or ($null -ne $json -and $json.is_error -eq $true))) {
        return @{ ok = $false; retryAt = (Get-QuotaRetryUtc $raw); message = 'claude usage limit reached (CLI output withheld)' }
    }
    if ($invocation.code -ne 0) {
        # A fixed category only, never the CLI's own text.
        $klass = 'provider_error'
        if     ($raw -match '(?i)(^|[^0-9])401([^0-9]|$)|unauthori[sz]ed|not logged in|authentication|expired') { $klass = 'authentication' }
        elseif ($raw -match '(?i)overloaded|(^|[^0-9])(500|502|503|529)([^0-9]|$)|internal server')            { $klass = 'provider_outage' }
        elseif ($raw -match '(?i)network|connection|econn|dns|certificate|tls|timed out')                       { $klass = 'network' }
        elseif ($raw -match '(?i)limit')                                                                        { $klass = 'unrecognised_limit' }
        return @{ ok = $false; message = "claude exited $($invocation.code) (class=$klass; CLI output withheld; 124 = timeout)" }
    }

    if ($null -eq $json -or $json.type -ne 'result' -or $json.subtype -ne 'success' -or $json.is_error -ne $false) {
        return @{ ok = $false; message = 'claude did not return a successful result (CLI output withheld)' }
    }

    $inTok = 0; $outTok = 0; $ms = 0
    try { $inTok  = [int] $json.usage.input_tokens }  catch { }
    try { $outTok = [int] $json.usage.output_tokens } catch { }
    try { $ms     = [int] $json.duration_ms }         catch { }
    if ($outTok -le 0) {
        return @{ ok = $false; message = 'claude returned no output tokens; quota-window activation is unverified' }
    }

    return @{
        ok = $true
        message = "claude ok (model=$(Get-Cfg 'CLAUDE_MODEL') in=$inTok out=$outTok ${ms}ms)"
    }
}

function Invoke-CodexPing {
    $exe = Resolve-Cli 'codex'
    if (-not $exe) {
        return @{ ok = $false; message = 'codex CLI not found - set CODEX_BIN in config.env, or npm i -g @openai/codex' }
    }

    $cliArgs = @('exec', '--skip-git-repo-check', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--json', '-s', 'read-only', '-c', 'project_doc_max_bytes=0', '-c', 'forced_login_method="chatgpt"', '-C', $WorkDir)

    $model = Get-Cfg 'CODEX_MODEL'
    if (-not [string]::IsNullOrWhiteSpace($model)) { $cliArgs += @('-m', $model) }

    $effort = Get-Cfg 'CODEX_REASONING_EFFORT'
    if (-not [string]::IsNullOrWhiteSpace($effort)) {
        $cliArgs += @('-c', ('model_reasoning_effort="{0}"' -f $effort))
    }

    $cliArgs += @('--', (Get-Cfg 'CODEX_PROMPT'))

    if ($DryRun) { return @{ ok = $true; message = "DRY RUN: codex $($cliArgs -join ' ')" } }

    $invocation = Invoke-BoundedCli $exe $cliArgs $WorkDir
    $raw = ($invocation.output, $invocation.errors) -join "`n"
    if ($invocation.code -ne 124 -and (Test-QuotaExhausted $raw) -and
        $raw -notmatch '"type"\s*:\s*"turn\.completed"') {
        return @{ ok = $false; retryAt = (Get-QuotaRetryUtc $raw); message = 'codex usage limit reached (CLI output withheld)' }
    }
    if ($invocation.code -ne 0) {
        return @{ ok = $false; message = "codex exited $($invocation.code) (CLI output withheld; 124 = timeout)" }
    }
    # Same rules as keepalive.sh.
    if ($raw -match '(?i)not logged in') { return @{ ok = $false; message = 'not logged in - run: codex login' } }
    if ($raw -match '(?m)^ERROR:') { return @{ ok = $false; message = 'codex reported an error (CLI output withheld)' } }

    $completed = $false
    foreach ($line in ($raw -split '\r?\n')) {
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
            if ($event.type -eq 'turn.failed' -or $event.type -eq 'error') {
                return @{ ok = $false; message = 'codex reported an error (CLI output withheld)' }
            }
            if ($event.type -eq 'turn.completed' -and $null -ne $event.usage) { $completed = $true }
        } catch { }
    }
    if (-not $completed) { return @{ ok = $false; message = 'codex returned no completed turn (CLI output withheld)' } }
    return @{ ok = $true; message = 'codex ok' }
}

# --------------------------------------------------------------------------
# Status report
# --------------------------------------------------------------------------
function Show-Status {
    $state = Read-State

    Write-Host ''
    Write-Host '  No 5-Hour Limit - status' -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------'
    Write-Host ("  config       : {0}" -f $ConfigPath)
    Write-Host ("  interval     : {0} minutes" -f $IntervalMinutes)

    $q = Get-Cfg 'QUIET_HOURS'
    if ($q) {
        $qState = 'inactive'
        if (Test-QuietHours) { $qState = 'ACTIVE right now' }
        Write-Host ("  quiet hours  : {0} ({1})" -f $q, $qState)
    } else {
        Write-Host '  quiet hours  : disabled (24/7)'
    }
    Write-Host ''

    foreach ($name in @('claude', 'codex')) {
        $enabled = Get-CfgBool ('{0}_ENABLED' -f $name.ToUpperInvariant())
        $label = $name.PadRight(6)

        if (-not $enabled) {
            Write-Host ("  {0}       : disabled" -f $label) -ForegroundColor DarkGray
            continue
        }

        $retry = Get-RetryUtc $state $name
        $fails = Get-FailureCount $state $name
        if ($null -ne $retry -and $retry -gt [datetime]::UtcNow -and $fails -gt 0) {
            Write-Host ("  {0}       : last {1} attempt(s) failed - next attempt {2} (see log)" -f $label, $fails, $retry.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Yellow
        } elseif ($null -ne $retry -and $retry -gt [datetime]::UtcNow) {
            Write-Host ("  {0}       : usage limit reached - next attempt {1}" -f $label, $retry.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Yellow
        }

        $last = Get-LastPingUtc $state $name
        if ($null -eq $last) {
            Write-Host ("  {0}       : enabled - no successful ping yet" -f $label) -ForegroundColor Yellow
            continue
        }

        $lastLocal  = $last.ToLocalTime()
        $windowEnds = $lastLocal.AddMinutes(300)
        $nextDue    = $lastLocal.AddMinutes($IntervalMinutes)
        $remaining  = $windowEnds - (Get-Date)

        $remainText = 'expired'
        if ($remaining.TotalSeconds -gt 0) {
            $remainText = '{0}h {1}m left' -f [math]::Floor($remaining.TotalHours), $remaining.Minutes
        }

        Write-Host ("  {0}       : enabled" -f $label) -ForegroundColor Green
        Write-Host ("     last ping   {0}" -f $lastLocal.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Host ("     estimated window end {0}  ({1}; not provider-reported)" -f $windowEnds.ToString('yyyy-MM-dd HH:mm:ss'), $remainText)
        Write-Host ("     next ping   {0}" -f $nextDue.ToString('yyyy-MM-dd HH:mm:ss'))
    }

    Write-Host ''
    # When driven from cloud.env, the local task is not what is running this.
    # Match the file name only, not a folder that happens to contain "cloud".
    if ((Split-Path -Leaf $ConfigPath) -eq 'cloud.env') {
        Write-Host '  scheduler    : GitHub Actions (.github/workflows/keepalive.yml)' -ForegroundColor Green
        Write-Host '     check runs  gh run list --workflow keepalive.yml'
        Write-Host ("  log file     : {0}" -f $LogFile)
        Write-Host ''
        return
    }

    $task = Get-ScheduledTask -TaskName 'No5HourLimit' -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host ("  scheduler    : installed, state = {0}" -f $task.State) -ForegroundColor Green
        $info = Get-ScheduledTaskInfo -TaskName 'No5HourLimit' -ErrorAction SilentlyContinue
        if ($info) { Write-Host ("     next check  {0}" -f $info.NextRunTime) }
    } else {
        Write-Host '  scheduler    : NOT INSTALLED - run install\install-windows.ps1 -EnableLocal' -ForegroundColor Yellow
    }
    Write-Host ("  log file     : {0}" -f $LogFile)
    Write-Host ''
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
if ($Status) {
    Show-Status
    exit 0
}

Remove-OldLogs

if ((Test-QuietHours) -and (-not $Force)) {
    Write-Log 'info' ("quiet hours active ({0}) - skipping" -f (Get-Cfg 'QUIET_HOURS'))
    exit 0
}

# An exclusive file handle also covers manual runs; Task Scheduler's
# IgnoreNew setting alone cannot do that. The OS releases it on a crash.
try {
    $runLock = [System.IO.File]::Open((Join-Path $StateDir '.lock-windows'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Log 'warn' 'another run is already working - skipping this one'
    exit 0
}
try {
$state   = Read-State
$anyFail = $false

foreach ($name in @('claude', 'codex')) {
    if (-not (Get-CfgBool ('{0}_ENABLED' -f $name.ToUpperInvariant()))) { continue }

    # Read the clock per provider: a slow first ping must not make the second
    # one look older than it is.
    $nowUtc = [datetime]::UtcNow

    $last = Get-LastPingUtc $state $name
    if ((-not $Force) -and ($null -ne $last)) {
        $elapsed = ($nowUtc - $last).TotalMinutes
        if ($elapsed -lt $IntervalMinutes) { continue }
    }
    $retry = Get-RetryUtc $state $name
    if ((-not $Force) -and ($null -ne $retry) -and ($nowUtc -lt $retry)) { continue }

    # An unexpected PowerShell error would otherwise abort only this statement
    # and leave the run looking successful. Never report its text.
    $result = $null
    try {
        if ($name -eq 'claude') { $result = Invoke-ClaudePing } else { $result = Invoke-CodexPing }
    } catch { $result = $null }
    if ($result -isnot [hashtable]) {
        $result = @{ ok = $false; message = "$name check failed inside PowerShell (details withheld)" }
    }

    if ($result.ok) {
        Write-Log 'info' $result.message
        if (-not $DryRun) {
            # Start the interval at the successful response. A slow CLI call
            # must not shorten the next five-hour window.
            $successUtc = [datetime]::UtcNow
            Set-ProviderEntry $state $name @{
                lastSuccessUtc = $successUtc.ToString('o')
                lastMessage    = $result.message
                retryAfterUtc  = $null
                failures       = $null
            }
            # Save straight away. Batching the write to the end means a hang on
            # the second provider throws away the first one's success, and the
            # next run pings it again for nothing.
            if (-not (Write-State $state)) { $anyFail = $true }
        }
    } elseif ($result.ContainsKey('retryAt')) {
        # Quota exhaustion is the provider working as designed, not a broken
        # job. Record when to try again and keep the exit status clean.
        Write-Log 'warn' ("{0}: {1} - next attempt {2}" -f $name, $result.message, $result.retryAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        if (-not $DryRun) {
            # The provider answered and knows the account: not a failure streak.
            Set-ProviderEntry $state $name @{ retryAfterUtc = $result.retryAt.ToString('o'); failures = $null }
            if (-not (Write-State $state)) { $anyFail = $true }
        }
    } else {
        $anyFail = $true
        if (-not $DryRun) {
            $fails = [math]::Min((Get-FailureCount $state $name) + 1, 100)
            $retryAt = Get-FailureRetryUtc $fails
            Write-Log 'error' ("{0}: {1} - failure {2} in a row, next attempt {3}" -f $name, $result.message, $fails, $retryAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
            Set-ProviderEntry $state $name @{ retryAfterUtc = $retryAt.ToString('o'); failures = $fails }
            [void] (Write-State $state)
        } else {
            Write-Log 'error' ("{0}: {1}" -f $name, $result.message)
        }
    }
}

} finally { $runLock.Dispose() }
if ($anyFail) { exit 1 }
exit 0
