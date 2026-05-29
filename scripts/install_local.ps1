# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# install_local.ps1 — Install the locally-built stax binary on Windows.
#
# Companion to install.ps1 that skips the GitHub-release download path and
# uses an artifact already on disk under .\bin\ (produced by `task build`).
# Intended for dogfooding the install flow without cutting a release.
#
# Usage:
#   task build; .\scripts\install_local.ps1
#   $env:BIN_DIR = 'C:\path\to\bin'; .\scripts\install_local.ps1
#
# Environment overrides:
#   BIN_DIR      Directory holding stax-windows-<arch>.exe artifacts
#                (default: <repo>\bin, derived from this script's location)
#   INSTALL_DIR  Destination directory (default: $HOME\.stax)

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binary     = 'stax'
$installDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $HOME '.stax' }

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

$configDir = Join-Path $HOME '.stax'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

# Seed the update-check config so the first post-install invocation does
# not probe the network. Mirrors install.ps1 exactly — same JSON structure,
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
# current session so `stax` is callable without restarting PowerShell.
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

# Seed ~/.stax/agents/ from the binary's embed via the dedicated
# post-install hook. Bare `stax` now launches the loopback web UI AND
# requires `<cwd>/.stax/_config.lock` to be present (it's a per-project
# tool from the user's point of view), so it would fail with
# "not a stax project" when invoked from the installer's working
# directory. `post-install` is the installer-only entry point that
# just materialises ~/.stax/agents/ and exits.
Info "Seeding ~/.stax/agents/ from binary"
& $dest post-install | Out-Null
if ($LASTEXITCODE -ne 0) { Die "stax first-run seed failed" }

Info "Installed. Run: $binary --help"
