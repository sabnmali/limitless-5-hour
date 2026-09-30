<#
.SYNOPSIS
    One command that finishes the cloud setup: creates the login token, stores
    it as a GitHub secret, starts the first due check and reports the result.

.DESCRIPTION
    Run this in a normal PowerShell window (Start menu -> type "powershell").
    It will:

      1. check that the gh and claude commands are available and signed in
      2. run `claude setup-token`, which opens your browser so you can approve
      3. ask you to paste the token it printed
      4. store that token as the CLAUDE_CODE_OAUTH_TOKEN repository secret
      5. enable the workflow, trigger a due check and wait for the result

    The token is never written to a file and never printed back.

.PARAMETER Repo
    owner/name of the GitHub repository. Detected from the git remote if the
    script is run from inside a clone.

.PARAMETER Codex
    Upload a verified ChatGPT-managed auth.json from a dedicated CODEX_HOME
    and enable Codex only in this private deployment repository.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install\setup-cloud-windows.ps1
#>
[CmdletBinding()]
param(
    [string] $Repo,
    [switch] $Codex
)

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Say  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  OK  $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  !   $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "  X   $m" -ForegroundColor Red; exit 1 }
function Head ($m) { Write-Host ''; Write-Host "  $m" -ForegroundColor Cyan }

Write-Host ''
Write-Host '  No 5-Hour Limit - cloud setup' -ForegroundColor Cyan
Write-Host '  ============================================================'

# --------------------------------------------------------------------------
# 0. Tools
# --------------------------------------------------------------------------
Head 'Step 1 of 5 - checking the tools'

$gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gh) {
    Die 'The GitHub CLI (gh) is not installed. Get it from https://cli.github.com then run this again.'
}
& $gh.Source auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Warn 'You are not signed in to GitHub. Starting the sign-in now...'
    & $gh.Source auth login
    & $gh.Source auth status *> $null
    if ($LASTEXITCODE -ne 0) { Die 'Still not signed in to GitHub - stopping.' }
}
Ok 'GitHub CLI ready'

function Find-Claude {
    $c = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in @(
        (Join-Path $env:APPDATA      'npm\claude.cmd'),
        (Join-Path $env:USERPROFILE  '.local\bin\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe')
    )) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

$claudePath = Find-Claude

if (-not $claudePath) {
    # Having the Claude desktop app does not put `claude` on your PATH - the app
    # carries its own private copy. The command-line tool is a separate install.
    Warn 'The claude command-line tool is not installed on this computer yet.'
    Say  '(The Claude desktop app has its own private copy that other programs cannot use.)'
    Say  ''

    $npm = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npm) {
        Die 'Installing it needs Node.js. Get it from https://nodejs.org then run this script again.'
    }

    $answer = Read-Host '  Install it now? (press Enter for yes, or type n)'
    if ($answer -match '^(?i:n|no|h|hayir)') {
        Die 'Nothing installed. Run this again when you are ready.'
    }

    Say 'Installing - this takes a minute...'
    & $npm.Source install -g '@anthropic-ai/claude-code'
    if ($LASTEXITCODE -ne 0) {
        Die 'The install failed. Try running this by hand:  npm install -g @anthropic-ai/claude-code'
    }

    # npm creates its global folder on first use, so this shell may not have
    # picked it up yet. Re-read PATH from the registry before looking again.
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'User') + ';' +
                [Environment]::GetEnvironmentVariable('PATH', 'Machine')

    $claudePath = Find-Claude
    if (-not $claudePath) {
        Die 'Installed, but the claude command still is not visible. Close this window, open a new PowerShell, and run this script again.'
    }
    Ok "claude installed: $claudePath"
} else {
    Ok "claude command found: $claudePath"
}

$claude = [pscustomobject]@{ Source = $claudePath }

# --------------------------------------------------------------------------
# 1. Which repository
# --------------------------------------------------------------------------
if (-not $Repo) {
    Push-Location $RepoRoot
    $remote = (& git remote get-url origin 2>$null)
    Pop-Location
    # Keep dots in the name and strip only a trailing .git. The old
    # ([^/.]+) turned owner/keep.alive.git into owner/keep, which would have
    # uploaded the token to a different repository or failed outright.
    if ($remote -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?\s*$') {
        $Repo = "$($Matches[1])/$($Matches[2])"
    }
}
if (-not $Repo) {
    Die 'Could not work out which GitHub repository to use. Re-run with:  -Repo owner/name'
}
Ok "repository: $Repo"

$visibility = (& $gh.Source repo view $Repo --json visibility --jq '.visibility' 2>$null)
if ($LASTEXITCODE -ne 0 -or $visibility -ne 'PRIVATE') {
    Die 'Cloud setup requires a PRIVATE deployment repository. Create one from the public template; never put subscription credentials in a public repository.'
}
Ok 'private deployment repository confirmed'

# --------------------------------------------------------------------------
# 2. The token
# --------------------------------------------------------------------------
Head 'Step 2 of 5 - creating your login token'
Say 'A browser window will open. Sign in and approve, then come back here.'
Say ''

& $claude.Source setup-token
if ($LASTEXITCODE -ne 0) { Die 'Token setup failed.' }

Say ''
Say 'Copy the long token printed above (select it with the mouse, then Ctrl+C)'
Say 'Nothing will appear as you paste - that is deliberate.'
# The CLI already put the token on screen once. Repeating it in the scrollback
# of a terminal that may be recorded is a needless second exposure.
$secure = Read-Host '  Paste it here, then press Enter' -AsSecureString
$bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
$token = ($token + '').Trim()

if ($token.Length -lt 20) {
    Die 'That does not look like a token. Run the script again and paste the whole line.'
}
Ok 'token received'

# --------------------------------------------------------------------------
# 3. Store it as a repository secret
# --------------------------------------------------------------------------
Head 'Step 3 of 5 - storing it on GitHub'

$token | & $gh.Source secret set CLAUDE_CODE_OAUTH_TOKEN --repo $Repo
if ($LASTEXITCODE -ne 0) { Die 'Could not store the secret. Check that you have access to the repository.' }
$token = $null
Ok 'CLAUDE_CODE_OAUTH_TOKEN stored (it is not saved anywhere on this computer)'
& $gh.Source variable set L5H_CLAUDE_ENABLED --body true --repo $Repo
if ($LASTEXITCODE -ne 0) { Die 'Claude credentials were stored, but the provider could not be enabled.' }
Ok 'cloud Claude enabled for this repository'

if ($Codex) {
    if (-not $env:CODEX_HOME) { Die 'Set CODEX_HOME to a separate cloud login directory first. See NETLIFY.md.' }
    if (-not (Test-Path -LiteralPath $env:CODEX_HOME -PathType Container)) { Die 'CODEX_HOME does not exist. Create it and run codex login there first. See NETLIFY.md.' }
    $dedicatedHome = [IO.Path]::GetFullPath($env:CODEX_HOME).TrimEnd('\', '/')
    $desktopHome = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')).TrimEnd('\', '/')
    if ($dedicatedHome -eq $desktopHome) { Die 'Do not upload the desktop login. Use a dedicated CODEX_HOME.' }
    $secretNames = & $gh.Source secret list --repo $Repo --json name --jq '.[].name'
    if ($LASTEXITCODE -ne 0 -or 'CODEX_SECRET_UPDATE_TOKEN' -notin $secretNames) { Die 'Create repository-scoped CODEX_SECRET_UPDATE_TOKEN first. See NETLIFY.md.' }
    $authFile = Join-Path $dedicatedHome 'auth.json'
    if (Test-Path -LiteralPath $authFile) {
        $authRaw = Get-Content -LiteralPath $authFile -Raw
        try { $authObject = $authRaw | ConvertFrom-Json -ErrorAction Stop } catch { Die 'Codex auth.json is not valid JSON.' }
        if ($authObject.auth_mode -ne 'chatgpt' -or [string]::IsNullOrWhiteSpace([string]$authObject.tokens.refresh_token)) {
            Die 'Codex auth.json is not a ChatGPT-managed login with a refresh token. See NETLIFY.md.'
        }
        $authRaw | & $gh.Source secret set CODEX_AUTH_JSON --repo $Repo
        $authRaw = $null
        $authObject = $null
        if ($LASTEXITCODE -ne 0) { Die 'Could not store CODEX_AUTH_JSON. Codex was not enabled.' }
        Ok 'CODEX_AUTH_JSON stored'
        & $gh.Source variable set L5H_CODEX_ENABLED --body true --repo $Repo
        if ($LASTEXITCODE -ne 0) { Die 'Credentials were stored, but Codex could not be enabled. Check repository Actions-variable access.' }
        Ok 'cloud Codex enabled for this repository'
        # The cloud copy now owns this login. Its first refresh retires the
        # local token, and using the local copy first would retire the cloud
        # one, so a leftover file is only a credential lying on disk.
        $answer = Read-Host ("  Delete the local copy {0} now? (press Enter for yes, or type n)" -f $authFile)
        if ($answer -match '^(?i:n|no)$') {
            Write-Host "  !   kept $authFile - do not run codex with this CODEX_HOME, or the cloud login stops working" -ForegroundColor Yellow
        } else {
            Remove-Item -LiteralPath $authFile -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $authFile) { Write-Host "  !   could not delete $authFile - remove it yourself" -ForegroundColor Yellow }
            else { Ok 'local copy deleted' }
        }
    } else {
        Die "No $authFile found. Run 'codex login' with that dedicated home first."
    }
}

# --------------------------------------------------------------------------
# 4. Open the first window
# --------------------------------------------------------------------------
Head 'Step 4 of 5 - starting the first due check'

& $gh.Source workflow enable keepalive.yml --repo $Repo
if ($LASTEXITCODE -ne 0) { Die 'Could not enable keepalive.yml in the private repository.' }

# Remember what already exists, so a run left over from cron is never mistaken
# for the one this script is about to start.
$before = @()
try {
    $before = (& $gh.Source run list --workflow keepalive.yml --event workflow_dispatch --limit 20 `
                  --json databaseId --repo $Repo 2>$null | ConvertFrom-Json).databaseId
} catch { }

& $gh.Source workflow run keepalive.yml --repo $Repo
if ($LASTEXITCODE -ne 0) { Die 'Could not start the workflow. Is Actions enabled on the repository?' }
Ok 'workflow started'

# --------------------------------------------------------------------------
# 5. Wait and report
# --------------------------------------------------------------------------
Head 'Step 5 of 5 - waiting for the result'

$runId = $null
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5

    # Pick the newest run that was not there before the dispatch, then follow
    # that fixed id. Watching "the latest run" could report success from a run
    # that finished before this script even started.
    if (-not $runId) {
        try {
            $listed = (& $gh.Source run list --workflow keepalive.yml --event workflow_dispatch --limit 20 `
                          --json databaseId --repo $Repo 2>$null | ConvertFrom-Json).databaseId
        } catch { $listed = @() }
        $runId = $listed | Where-Object { $before -notcontains $_ } | Select-Object -First 1
        if (-not $runId) { Write-Host '.' -NoNewline; continue }
    }

    $json = & $gh.Source run view $runId --json status,conclusion --repo $Repo 2>$null
    if (-not $json) { continue }
    try { $run = $json | ConvertFrom-Json } catch { continue }
    if (-not $run) { continue }
    if ($run.status -eq 'completed') {
        Write-Host ''
        if ($run.conclusion -eq 'success') {
            Ok 'Due check completed. In a fresh deployment, inspect the provider job for actual success; reset times are estimates.'
            Write-Host ''
            Say "Details: https://github.com/$Repo/actions/runs/$runId"
            Write-Host ''
            Write-Host '  Nothing else to do. You can close this window.' -ForegroundColor Green
            Write-Host ''
            exit 0
        }
        Warn "The run finished with: $($run.conclusion)"
        Say  "Look at what went wrong: https://github.com/$Repo/actions/runs/$runId"
        Say  'The most common cause is a token that was pasted incomplete - just run this script again.'
        exit 1
    }
    Write-Host '.' -NoNewline
}

Write-Host ''
Warn 'Verification timed out after 3 minutes; outcome unknown. Check:'
Say  "https://github.com/$Repo/actions"

exit 1
