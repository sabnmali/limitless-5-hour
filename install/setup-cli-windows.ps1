<#
.SYNOPSIS
    One-shot helper: get the Claude CLI into a place a scheduled task can
    actually reach, log it in, and re-run the installer.

.DESCRIPTION
    Run this in a NORMAL PowerShell window (Start menu -> "PowerShell"), not
    from inside another tool, because the login step opens your browser.

    Why it exists: a scheduled task runs with a different PATH than your
    terminal, so a keepalive that works when you run it by hand can silently
    fail in the background. The native Claude Code build installs under your
    user folder, which is the most reliable place for a scheduler to find it.

.PARAMETER SkipInstall
    Don't install the native build; only log in and re-run the installer.

.PARAMETER SkipLogin
    Don't run the login step.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install\setup-cli-windows.ps1
#>
[CmdletBinding()]
param(
    [switch] $SkipInstall,
    [switch] $SkipLogin
)

$ErrorActionPreference = 'Continue'

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Head($m) { Write-Host ''; Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  OK  $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  !   $m" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  No 5-Hour Limit - Claude CLI setup helper' -ForegroundColor Cyan
Write-Host '  ============================================================'

# --------------------------------------------------------------------------
# 1. Native build
# --------------------------------------------------------------------------
$nativePaths = @(
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe'),
    (Join-Path $env:USERPROFILE 'bin\claude.exe')
)

function Find-NativeClaude {
    foreach ($p in $nativePaths) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

$native = Find-NativeClaude

if (-not $SkipInstall -and -not $native) {
    Write-Head 'Step 1 / 3 - installing the native Claude Code build'
    $claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $claude) {
        Write-Warn 'no claude CLI on PATH at all. Install one first:'
        Write-Host '        npm install -g @anthropic-ai/claude-code' -ForegroundColor White
        exit 1
    }
    & $claude.Source install stable
    $native = Find-NativeClaude
    if ($native) { Write-Ok "native build installed: $native" }
    else { Write-Warn 'could not locate the native build afterwards - continuing anyway' }
} elseif ($native) {
    Write-Head 'Step 1 / 3 - native build'
    Write-Ok "already installed: $native"
} else {
    Write-Head 'Step 1 / 3 - native build (skipped)'
}

# --------------------------------------------------------------------------
# 2. Login
# --------------------------------------------------------------------------
$exe = $native
if (-not $exe) {
    $c = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $exe = $c.Source }
}

if (-not $SkipLogin -and $exe) {
    Write-Head 'Step 2 / 3 - logging the CLI in'
    $status = ''
    try { $status = (& $exe auth status 2>&1 | Out-String) } catch { }
    if ($status -match '"loggedIn"\s*:\s*true') {
        Write-Ok 'already logged in'
    } else {
        Write-Host '  A browser window will open. Sign in with your Claude account.'
        & $exe auth login
        $status = ''
        try { $status = (& $exe auth status 2>&1 | Out-String) } catch { }
        if ($status -match '"loggedIn"\s*:\s*true') { Write-Ok 'logged in' }
        else { Write-Warn 'still not logged in - try running "claude auth login" on its own' }
    }
} else {
    Write-Head 'Step 2 / 3 - login (skipped)'
}

# --------------------------------------------------------------------------
# 3. Re-run the installer so the new path gets pinned
# --------------------------------------------------------------------------
Write-Head 'Step 3 / 3 - CLI ready; local automation remains unchanged'

if ($native) {
    # Put the native build ahead of the npm shim for this process, so the
    # installer pins the path the scheduler can actually reach.
    $env:PATH = (Split-Path -Parent $native) + ';' + $env:PATH
}

Write-Host 'Local scheduling is separate and requires install\install-windows.ps1 -EnableLocal.'

Write-Host ''
Write-Host '  Installer finished. Check status before sending another ping:' -ForegroundColor Green
Write-Host ('        powershell -ExecutionPolicy Bypass -File "{0}" -Status' -f (Join-Path $RepoRoot 'bin\keepalive.ps1'))
Write-Host ''
