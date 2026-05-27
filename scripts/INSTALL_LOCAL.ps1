# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# INSTALL_LOCAL.ps1 — Install the locally-built x-x binary on Windows.
#
# Companion to INSTALL.ps1 that skips the GitHub-release download path and
# uses an artifact already on disk under .\bin\ (produced by `task build`).
# Intended for dogfooding the install flow without cutting a release.
#
# Usage:
#   task build; .\scripts\INSTALL_LOCAL.ps1
#   $env:BIN_DIR = 'C:\path\to\bin'; .\scripts\INSTALL_LOCAL.ps1
#
# Environment overrides:
#   BIN_DIR      Directory holding x-x-windows-<arch>.exe artifacts
#                (default: <repo>\bin, derived from this script's location)
#   INSTALL_DIR  Destination directory (default: $HOME\.x-x)

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binary     = 'x-x'
$installDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $HOME '.x-x' }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$binDir    = if ($env:BIN_DIR) { $env:BIN_DIR } else { Join-Path $scriptDir '..\bin' }

function Info($msg) { Write-Host "==> $msg" }
function Die($msg)  { Write-Error $msg; exit 1 }

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { 'amd64' }
  'ARM64' { 'arm64' }
  default { Die "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}

$asset      = "$binary-windows-$arch.exe"
$sourcePath = Join-Path $binDir $asset

if (-not (Test-Path -LiteralPath $sourcePath)) {
  Die "binary not found: $sourcePath`nrun ``task build`` from the repo root first, or set BIN_DIR"
}

$dest = Join-Path $installDir "$binary.exe"
Info "Installing $sourcePath to $dest"
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
# Copy rather than move — the source artifact under .\bin\ stays available
# for repeat installs and the other-arch sibling file.
Copy-Item -Force -Path $sourcePath -Destination $dest

$configDir = Join-Path $HOME '.x-x'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

# Seed the update-check config so the first post-install invocation does
# not probe the network. Mirrors INSTALL.ps1 exactly — same JSON structure,
# same version-string parse (last whitespace-separated token on the first
# `--version` line).
$installedVersion = try {
  $firstLine = (& $dest --version 2>$null) | Select-Object -First 1
  if ($firstLine) { ($firstLine -split '\s+')[-1] } else { 'unknown' }
} catch { 'unknown' }
if (-not $installedVersion) { $installedVersion = 'unknown' }
$epoch = [int64](([DateTimeOffset]::UtcNow).ToUnixTimeSeconds())
$configPath = Join-Path $configDir '.config.json'
$configJson = [ordered]@{
  version      = $installedVersion
  last_checked = $epoch
} | ConvertTo-Json
Set-Content -Path $configPath -Value $configJson -Encoding ascii

# Persist on the user PATH (visible to every new shell) and patch the
# current session so `x-x` is callable without restarting PowerShell.
# SetEnvironmentVariable writes the registry directly, sidestepping the
# 1024/2047-char truncation that `setx` imposes.
$userPath  = [Environment]::GetEnvironmentVariable('Path', 'User')
$userPaths = if ($userPath) { $userPath -split ';' } else { @() }
if ($userPaths -notcontains $installDir) {
  $newUserPath = if ($userPath) { "$installDir;$userPath" } else { $installDir }
  [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
  Info "Added $installDir to user PATH"
}
if (($env:Path -split ';') -notcontains $installDir) {
  $env:Path = "$installDir;$env:Path"
}

# Seed ~/.x-x/agents/ from the binary's embed via a bare invocation. Same
# trick the release installer uses; refreshes are handled by the 24h
# update check from then on.
Info "Seeding ~/.x-x/agents/ from binary"
& $dest | Out-Null
if ($LASTEXITCODE -ne 0) { Die "x-x first-run seed failed" }

Info "Installed. Run: $binary --help"
