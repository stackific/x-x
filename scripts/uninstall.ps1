# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# uninstall.ps1 — Remove a stax installation on Windows.
#
# Usage:
#   irm https://raw.githubusercontent.com/stackific/stax/main/scripts/uninstall.ps1 | iex
#   $env:INSTALL_DIR = 'C:\tools\stax'; irm https://raw.githubusercontent.com/stackific/stax/main/scripts/uninstall.ps1 | iex
#
# Environment overrides:
#   INSTALL_DIR  Directory the binary was installed into (default: $HOME\.stax).
#                Must match whatever was passed to install.ps1; otherwise the
#                binary is left in place.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binary     = 'stax'
$installDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $HOME '.stax' }
$configDir  = Join-Path $HOME '.stax'

function Info($msg) { Write-Host "==> $msg" }
function Warn($msg) { Write-Warning $msg }

# 1. Have the binary clean up the user-scope skills it installed
# ($HOME\.claude\skills, $HOME\.codex\skills, etc.). Must run BEFORE we delete
# the binary in step 2. Best-effort: if the binary is missing or fails, we
# warn and keep going so the user still gets a partial cleanup.
$dest = Join-Path $installDir "$binary.exe"
if (Test-Path -LiteralPath $dest) {
  Info "Removing stax-managed user-scope skills"
  try {
    & $dest skills remove --user
    if ($LASTEXITCODE -ne 0) { Warn "stax skills remove --user exited $LASTEXITCODE; continuing" }
  } catch {
    Warn "stax skills remove --user failed: $_; continuing"
  }
} else {
  Warn "$dest not found; skipping user-scope skill cleanup"
}

# 2. Remove the installed binary.
if (Test-Path -LiteralPath $dest) {
  Info "Removing $dest"
  Remove-Item -LiteralPath $dest -Force
} else {
  Warn "$dest not found; skipping"
}

# 3. Remove $HOME\.stax\ (.config.json + agents/ cache + the binary if installed there).
# Guard against catastrophic INSTALL_DIR / HOME values.
$forbidden = @($HOME, [System.IO.Path]::GetPathRoot($HOME), '', $null)
if (Test-Path -LiteralPath $configDir) {
  if ($forbidden -contains $configDir) {
    Write-Error "refusing to remove $configDir"
    exit 1
  }
  Info "Removing $configDir"
  Remove-Item -LiteralPath $configDir -Recurse -Force
} else {
  Warn "$configDir not found; skipping"
}

# 4. Strip $installDir from the User PATH (persistent) and from the current
# session. Uses [Environment]::SetEnvironmentVariable for the same reason
# install.ps1 does: it writes the registry directly and sidesteps `setx`'s
# 1024/2047-char truncation.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
  $entries = $userPath -split ';'
  $filtered = $entries | Where-Object { $_ -and ($_ -ne $installDir) }
  if ($filtered.Count -ne $entries.Count) {
    $newUserPath = ($filtered -join ';')
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Info "Removed $installDir from user PATH"
  } else {
    Info "$installDir not present in user PATH; skipping"
  }
} else {
  Info "User PATH is empty; skipping"
}

# Patch the current session too so a subsequent `stax` in this shell fails
# fast instead of resolving to a now-missing binary.
$sessionEntries = $env:Path -split ';' | Where-Object { $_ -and ($_ -ne $installDir) }
$env:Path = ($sessionEntries -join ';')

Info "Uninstalled."
