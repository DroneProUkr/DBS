#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
install.ps1 — Windows installer for dbs (Drone Build System).

dbs is a Linux/Docker tool; on Windows it runs unchanged inside WSL2. This
installer:

  1. installs (or updates) dbs *inside* WSL by reusing the canonical install.sh,
  2. drops the Windows shim (dbs.ps1) into ~/bin,
  3. registers a `dbs` function in your pwsh profile so `dbs ...` works in any
     PowerShell 7 session.

One-liner (from PowerShell 7):
  irm https://raw.githubusercontent.com/DroneProUkr/DBS/main/install.ps1 | iex

For options (deps / a non-default distro), download and run it instead:
  iwr https://raw.githubusercontent.com/DroneProUkr/DBS/main/install.ps1 -OutFile install.ps1
  ./install.ps1 -InstallDeps -Distro Ubuntu

Re-running is safe: the WSL checkout is git-pulled, the shim re-copied, and the
profile block updated in place.
#>
[CmdletBinding()]
param(
    [string]$Distro,
    [string]$BinDir = (Join-Path $env:USERPROFILE 'bin'),
    [switch]$InstallDeps
)
$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

# --- 0. wsl.exe + pwsh ------------------------------------------------------
$wsl = (Get-Command wsl.exe -ErrorAction SilentlyContinue).Source
if (-not $wsl) { Die "wsl.exe not found. Install WSL2 first:  wsl --install   (https://aka.ms/wsl)" }

$pwshCmd = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshCmd) { Die "PowerShell 7 (pwsh) not found. Install it (winget install Microsoft.PowerShell) and re-run." }

# --- 1. pick a Linux distro (never docker-desktop) --------------------------
function Get-WslDistros {
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode   # wsl.exe emits UTF-16LE
        $raw = & $wsl --list --quiet 2>$null
    } finally { [Console]::OutputEncoding = $prev }
    $raw | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ }
}

$distros = Get-WslDistros
if (-not $distros) { Die "no WSL distro installed.  wsl --install -d Ubuntu" }

if (-not $Distro) { $Distro = $env:DBS_WSL_DISTRO }
if (-not $Distro) { $Distro = $distros | Where-Object { $_ -notlike 'docker-desktop*' } | Select-Object -First 1 }
if (-not $Distro) { Die "no usable Linux distro (only docker-desktop present).  wsl --install -d Ubuntu" }
if ($distros -notcontains $Distro) { Die "WSL distro '$Distro' not found. Available: $($distros -join ', ')" }
Info "Using WSL distro: $Distro"
$d = @('-d', $Distro)

# --- 2. dependencies inside WSL --------------------------------------------
if ($InstallDeps) {
    Info "Installing Linux build prerequisites in $Distro (sudo may prompt for your password)"
    & $wsl @d -e bash -lc 'sudo apt-get update && sudo apt-get install -y git curl python3 python3-git'
    if ($LASTEXITCODE -ne 0) { Warn "dependency install reported an error — continuing" }
}

# docker comes from Docker Desktop's WSL integration, not apt.
# `-e` (exec) form throughout: `--`/bare wsl drops args after a `-c` script.
$dockerOk = (& $wsl @d -e bash -lc 'command -v docker >/dev/null 2>&1 && echo yes || echo no').Trim()
if ($dockerOk -ne 'yes') {
    Warn "docker not found in $Distro. Enable Docker Desktop -> Settings -> Resources -> WSL integration for '$Distro'."
}

# --- 3. install dbs inside WSL (reuse the canonical install.sh) -------------
Info "Installing dbs inside $Distro"
$localInstaller = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'install.sh' } else { $null }
if ($localInstaller -and (Test-Path $localInstaller)) {
    $shPath = (& $wsl @d -e wslpath -a -u $localInstaller).Trim()
    & $wsl @d -e bash -lc 'sh "$1"' sh $shPath
} else {
    & $wsl @d -e bash -lc 'curl -fsSL https://raw.githubusercontent.com/DroneProUkr/DBS/main/install.sh | sh'
}
if ($LASTEXITCODE -ne 0) { Die "dbs install inside WSL failed (see messages above)." }

# --- 4. place the Windows shim (dbs.ps1) -----------------------------------
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$shimDst  = Join-Path $BinDir 'dbs.ps1'
$localShim = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'dbs.ps1' } else { $null }
if ($localShim -and (Test-Path $localShim)) {
    Copy-Item $localShim $shimDst -Force
} else {
    Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/DroneProUkr/DBS/main/dbs.ps1' -OutFile $shimDst
}
Info "Installed shim: $shimDst"

# --- 5. register a `dbs` function in the pwsh profile ----------------------
# .ps1 isn't in PATHEXT, so a bare `dbs` won't resolve dbs.ps1 — a profile
# function is the clean pwsh-only entry point.
$profilePath = (& $pwshCmd -NoProfile -Command 'Write-Output $PROFILE.CurrentUserAllHosts').Trim()
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $profilePath) | Out-Null

$begin = '# >>> dbs shim >>>'
$end   = '# <<< dbs shim <<<'
$block = @(
    $begin
    "function dbs { & '$shimDst' @args }"
    $end
) -join "`r`n"

$existing = if (Test-Path $profilePath) { Get-Content -Raw -LiteralPath $profilePath } else { '' }
if ($existing -match [regex]::Escape($begin)) {
    $pattern = "(?s)" + [regex]::Escape($begin) + ".*?" + [regex]::Escape($end)
    $updated = [regex]::Replace($existing, $pattern, { param($m) $block })
    Set-Content -LiteralPath $profilePath -Value $updated -NoNewline
    Info "Updated dbs function in $profilePath"
} else {
    $sep = if ($existing.Length -and -not $existing.EndsWith("`n")) { "`r`n" } else { '' }
    Add-Content -LiteralPath $profilePath -Value ($sep + $block + "`r`n")
    Info "Added dbs function to $profilePath"
}

# Make `dbs` usable right now if this script was dot-sourced / piped to iex.
Set-Item -Path Function:global:dbs -Value ([scriptblock]::Create("& '$shimDst' @args")) -Force

Write-Host ''
Info "Done. Open a new PowerShell 7 window (or run the line below), then 'dbs --help'."
Write-Host "     . `$PROFILE.CurrentUserAllHosts" -ForegroundColor DarkGray
