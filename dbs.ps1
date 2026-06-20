#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
dbs.ps1 — Windows shim for the dbs (Drone Build System) CLI.

dbs is a Linux/Docker tool. On Windows the canonical `dbs` script runs
*unchanged* inside WSL2 — the environment it is built for (real dpkg, GitPython,
and Docker Desktop's docker CLI). This shim forwards every invocation into WSL:

  * sets the WSL working directory to the current Windows directory (wsl --cd),
  * translates a Windows path *argument* (the optional PROJECT_DIR / init DIR)
    into its /mnt/<drive>/... form so dbs inside WSL sees a real path,
  * runs dbs in a login shell so ~/bin (dbs) and Docker Desktop's docker are on
    PATH,
  * forwards the exit code verbatim.

Install dbs into WSL and put this shim on PATH with install.ps1.
Override the target distro with $env:DBS_WSL_DISTRO (default: the WSL default).

Notes:
  - Windows paths are auto-translated; a leading-`~` path is NOT expanded
    (it is quoted data to dbs) — pass a Windows path or an absolute WSL path.
  - Everything after `--` is forwarded to `docker build` untouched.
#>
$ErrorActionPreference = 'Stop'

$wsl = (Get-Command wsl.exe -ErrorAction SilentlyContinue).Source
if (-not $wsl) {
    [Console]::Error.WriteLine("dbs: wsl.exe not found. Install WSL2 (https://aka.ms/wsl), then run install.ps1.")
    exit 1
}

$distroArgs = @()
if ($env:DBS_WSL_DISTRO) { $distroArgs = @('-d', $env:DBS_WSL_DISTRO) }

# Translate one argument: leave flags, the `init` keyword and flag *values*
# alone; convert a Windows path (PROJECT_DIR / init DIR) to its WSL /mnt form.
# Linux-style paths (no backslash, no drive letter) pass through untouched.
function Convert-DbsArg([string]$a) {
    if ($a.StartsWith('-')) { return $a }            # flag, e.g. -a / --dist / -DK=V
    if ($a -eq 'init') { return $a }                 # subcommand keyword
    $isWinPath = ($a -match '^[A-Za-z]:[\\/]') -or `
                 ($a -match '^\\\\') -or `
                 ($a.Contains('\')) -or `
                 (Test-Path -LiteralPath $a -ErrorAction SilentlyContinue)
    if (-not $isWinPath) { return $a }
    try {
        $full = if ([System.IO.Path]::IsPathRooted($a)) {
            [System.IO.Path]::GetFullPath($a)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $a))
        }
    } catch { return $a }
    $u = (& $wsl @distroArgs -e wslpath -a -u $full 2>$null)
    if ($LASTEXITCODE -eq 0 -and $u) { return ([string]$u).Trim() }
    return $a
}

# Walk the arguments, translating paths but skipping value-taking flags' values
# and everything after a `--` separator.
$valueFlags = @('-d', '--dist', '-a', '--arch', '--host-deps', '-D')
$fwd = New-Object System.Collections.Generic.List[string]
$afterSep = $false
$expectValue = $false
foreach ($raw in $args) {
    $s = [string]$raw
    if ($afterSep)         { $fwd.Add($s); continue }
    if ($s -eq '--')       { $afterSep = $true; $fwd.Add('--'); continue }
    if ($expectValue)      { $fwd.Add($s); $expectValue = $false; continue }
    if ($valueFlags -contains $s) { $fwd.Add($s); $expectValue = $true; continue }
    $fwd.Add((Convert-DbsArg $s))
}

$cwd = (Get-Location).ProviderPath
# Login shell so ~/bin (dbs) and Docker Desktop's docker land on PATH. The PATH
# prefix is belt-and-suspenders in case ~/.bashrc doesn't add ~/bin.
$remote = 'PATH="$HOME/bin:$PATH"; exec dbs "$@"'

# `-e` (exec), NOT `--`: with `--`/bare, wsl.exe drops positional args after a
# `-c` script, so dbs would get no args and an empty PROJECT_DIR. `-e` execs the
# argv directly, so `$@` reaches dbs intact.
$wslArgs = @()
$wslArgs += $distroArgs
$wslArgs += @('--cd', $cwd, '-e', 'bash', '-lc', $remote, 'dbs')
$wslArgs += $fwd.ToArray()

& $wsl @wslArgs
$code = $LASTEXITCODE
if ($code -eq 127) {
    $d = if ($distroArgs.Count) { " ($($distroArgs -join ' '))" } else { '' }
    [Console]::Error.WriteLine("dbs: 'dbs' not found inside WSL$d. Run install.ps1 to set it up.")
}
exit $code
