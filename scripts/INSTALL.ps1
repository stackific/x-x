# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# INSTALL.ps1 — Download and install the latest x-x release on Windows.
#
# Usage:
#   irm https://raw.githubusercontent.com/stackific/x-x/main/scripts/INSTALL.ps1 | iex
#   $env:INSTALL_DIR = 'C:\tools\x-x'; irm https://raw.githubusercontent.com/stackific/x-x/main/scripts/INSTALL.ps1 | iex
#
# Environment overrides:
#   INSTALL_DIR  Destination directory (default: $HOME\.x-x)
#   VERSION      Specific release tag, e.g. v0.1.0 (default: latest)

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo   = 'stackific/x-x'
$binary = 'x-x'
$installDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $HOME '.x-x' }
$version    = if ($env:VERSION)     { $env:VERSION }     else { 'latest' }

function Info($msg) { Write-Host "==> $msg" }
function Die($msg)  { Write-Error $msg; exit 1 }

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { 'amd64' }
  'ARM64' { 'arm64' }
  default { Die "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}

$asset = "$binary-windows-$arch.exe"
$base  = if ($version -eq 'latest') {
  "https://github.com/$repo/releases/latest/download"
} else {
  "https://github.com/$repo/releases/download/$version"
}

$tmpdir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
New-Item -ItemType Directory -Path $tmpdir | Out-Null
try {
  $assetPath     = Join-Path $tmpdir $asset
  $checksumsPath = Join-Path $tmpdir 'checksums.txt'

  Info "Downloading $asset"
  Invoke-WebRequest -Uri "$base/$asset" -OutFile $assetPath -UseBasicParsing

  Info "Downloading checksums.txt"
  Invoke-WebRequest -Uri "$base/checksums.txt" -OutFile $checksumsPath -UseBasicParsing

  Info "Verifying SHA-256"
  $expected = Get-Content $checksumsPath |
    Where-Object { $_ -match "\s$([regex]::Escape($asset))$" } |
    ForEach-Object { ($_ -split '\s+')[0] } |
    Select-Object -First 1
  if (-not $expected) { Die "asset $asset not listed in checksums.txt" }

  # Get-FileHash returns uppercase; sha256sum writes lowercase. Normalize both.
  $actual = (Get-FileHash -Algorithm SHA256 -Path $assetPath).Hash.ToLower()
  if ($expected -ne $actual) { Die "checksum mismatch: expected $expected, got $actual" }

  $dest = Join-Path $installDir "$binary.exe"
  Info "Installing to $dest"
  New-Item -ItemType Directory -Force -Path $installDir | Out-Null
  Move-Item -Force -Path $assetPath -Destination $dest

  $configDir = Join-Path $HOME '.x-x'
  New-Item -ItemType Directory -Force -Path $configDir | Out-Null

  # Seed the update-check config. The CLI reads ~/.x-x/.config.json on every run
  # and consults the GitHub API at most once per 24h to nudge stale installs.
  # Writing last_checked=<now> here means the first post-install invocation
  # does not probe the network.
  # `x-x --version` prints the full notice; the version itself is the last
  # whitespace-separated token on line 1 ("x-x by Stackific, v0.1.0").
  $installedVersion = try {
    $firstLine = (& $dest --version 2>$null) | Select-Object -First 1
    if ($firstLine) { ($firstLine -split '\s+')[-1] } else { 'unknown' }
  } catch { 'unknown' }
  if (-not $installedVersion) { $installedVersion = 'unknown' }
  $epoch = [int64](([DateTimeOffset]::UtcNow).ToUnixTimeSeconds())
  $configPath = Join-Path $configDir '.config.json'
  # ConvertTo-Json handles escaping (quotes, backslashes, control chars) for us.
  $configJson = [ordered]@{
    version      = $installedVersion
    last_checked = $epoch
  } | ConvertTo-Json
  Set-Content -Path $configPath -Value $configJson -Encoding ascii

  # Persist on the user PATH (visible to every new shell) and patch the
  # current session so `x-x` is callable without restarting PowerShell.
  # SetEnvironmentVariable writes the registry directly, sidestepping the
  # 1024/2047-char truncation that `setx` imposes.
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $userPaths = if ($userPath) { $userPath -split ';' } else { @() }
  if ($userPaths -notcontains $installDir) {
    $newUserPath = if ($userPath) { "$installDir;$userPath" } else { $installDir }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Info "Added $installDir to user PATH"
  }
  if (($env:Path -split ';') -notcontains $installDir) {
    $env:Path = "$installDir;$env:Path"
  }

  # Seed the bundled agents/ library from the binary's embed.
  # `post-install` is the dedicated installer subcommand: it triggers
  # the lazy first-run write to ~/.x-x/agents/ and exits silently,
  # NEVER opening a browser. We must not use bare `x-x` here — that
  # branch opens https://google.com in the user's default browser,
  # which would pop a window mid-install. The 24h update check (still
  # bound to every invocation) handles refreshes from then on.
  Info "Seeding ~/.x-x/agents/ from binary"
  & $dest post-install | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "x-x first-run seed failed" }

  Info "Installed. Run: $binary --help"
} finally {
  Remove-Item -Recurse -Force -Path $tmpdir -ErrorAction SilentlyContinue
}
