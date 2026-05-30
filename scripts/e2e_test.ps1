#!/usr/bin/env pwsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# e2e_test.ps1 — End-to-end test driver for the stax CLI on Windows.
#
# Companion to scripts/e2e_test.sh that targets PowerShell semantics and
# Windows-specific behavior (no symlinks without Dev Mode, %USERPROFILE%
# instead of $HOME, CRLF line endings, backslash path separators, reserved
# filenames, case-insensitive filesystem). Builds the binary, installs it
# into an isolated %USERPROFILE%, exercises every subcommand, asserts the
# documented side effects.
#
# Designed to run on `windows-latest` via
# .github/workflows/windows-cli.yml. Also runnable locally on a Windows
# host with PowerShell 7+ and Go on PATH:
#
#   pwsh -File scripts\e2e_test.ps1
#
# Exits 0 on success, 1 on the first assertion failure. Every failure prints
# the offending case + actual/expected AND the captured stdout/stderr/exit
# code from the last Invoke-XX call, so the log is self-diagnosing.
#
# Pass -Verbose to also print stdout/stderr/RC on EVERY Invoke-XX call (not
# just failures). Useful when iterating on a test that's mysteriously
# passing or failing for the wrong reason.

param(
  [switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Honor -Verbose at the script level so any nested Write-Verbose calls fire.
if ($Verbose) { $VerbosePreference = 'Continue' }

# Capture the harness's own -Verbose flag in script scope so helpers can
# branch on it without re-reading the parameter.
$Script:VerboseMode = [bool]$Verbose

# ---------- path constants (mirror of constants.go) ----------
#
# AGENTS.md hard rule: every on-disk path component referenced by *any*
# source — Go or shell or PowerShell — flows from a single source of truth
# (constants.go). This block is the PowerShell mirror. Add/rename a path in
# constants.go → mirror it here in the same change. TestE2EShellConstantsMatchGo
# in constants_e2e_test.go enforces parity for the bash mirror; an analogous
# Go test should be added if this file's mirror grows much further.

Set-Variable -Option Constant -Name STAX_DIR                       -Value '.stax'
Set-Variable -Option Constant -Name STAX_CONFIG_FILE                -Value '.config.json'
Set-Variable -Option Constant -Name AGENTS_EMBED_ROOT               -Value 'agents'
Set-Variable -Option Constant -Name SKILLS_SUBDIR                   -Value 'skills'
Set-Variable -Option Constant -Name STAX_LOCK_FILE                  -Value '_config.lock'
Set-Variable -Option Constant -Name STAX_SYSTEMS_FILE               -Value '_data_systems.yaml'
Set-Variable -Option Constant -Name DEFAULT_PREFIX_WIDTH            -Value 4
Set-Variable -Option Constant -Name WORK_ITEMS_LIST_OVERFLOW_THRESHOLD   -Value 20

Set-Variable -Option Constant -Name SKILL_SCOPE_DIR     -Value 'scope'
Set-Variable -Option Constant -Name SKILL_SHIP_DIR      -Value 'ship'
Set-Variable -Option Constant -Name SKILL_MANIFEST_FILE -Value 'SKILL.md'

Set-Variable -Option Constant -Name OWNED_SKILLS -Value @($SKILL_SCOPE_DIR, $SKILL_SHIP_DIR)

# Mirrors of agentTargets[*].skillsRel / userSkillsRel / configRel in
# constants.go. The Go registry is sorted alphabetically by display name
# (case-insensitive) and looked up by `key` in the Go drift check, so
# these constants are matched by NAME, not by index. Codex, Copilot, Pi,
# and Zed all resolve skills from `.agents\skills` at workspace scope
# (cross-agent open spec, install is idempotent so the rows co-exist
# on disk without conflict). Claude and OpenCode stay on their own
# paths because their lookup logic doesn't include `.agents\skills`.
# OpenCode, Copilot, and Pi ship no per-agent config today (configRel
# is ""), so there are no *_CONFIG_REL mirrors for them. Cursor
# diverges across scopes (workspace `.agents\skills`, global
# `~\.cursor\skills`) — represented in Go via agentTarget.userSkillsRel.
Set-Variable -Option Constant -Name CLAUDE_SKILLS_REL           -Value '.claude\skills'
Set-Variable -Option Constant -Name CLAUDE_CONFIG_REL           -Value '.claude'
Set-Variable -Option Constant -Name CODEX_SKILLS_REL            -Value '.agents\skills'
Set-Variable -Option Constant -Name CODEX_CONFIG_REL            -Value '.codex'
Set-Variable -Option Constant -Name CURSOR_SKILLS_REL           -Value '.agents\skills'
Set-Variable -Option Constant -Name CURSOR_USER_SKILLS_REL      -Value '.cursor\skills'
Set-Variable -Option Constant -Name COPILOT_SKILLS_REL          -Value '.agents\skills'
# Copilot hook surface — scope-asymmetric (`userConfigRel` set in Go).
Set-Variable -Option Constant -Name COPILOT_CONFIG_REL           -Value '.github\hooks'
Set-Variable -Option Constant -Name COPILOT_USER_CONFIG_REL      -Value '.copilot\hooks'
# Google Antigravity — dual user-scope skill destinations plus scope-
# symmetric JSON hooks at `.gemini\settings.json`. The CLI-local skills
# root is consumed by the Antigravity CLI (`agy`); the shared skills
# root is read by both the CLI and the Antigravity Desktop app. See the
# matching bash mirror block + the agentTargets row comment for the full
# rationale.
Set-Variable -Option Constant -Name ANTIGRAVITY_SKILLS_REL             -Value '.agents\skills'
Set-Variable -Option Constant -Name ANTIGRAVITY_USER_SKILLS_REL_CLI    -Value '.gemini\antigravity-cli\skills'
Set-Variable -Option Constant -Name ANTIGRAVITY_USER_SKILLS_REL_SHARED -Value '.gemini\config\skills'
Set-Variable -Option Constant -Name ANTIGRAVITY_CONFIG_REL             -Value '.gemini'
Set-Variable -Option Constant -Name KILO_SKILLS_REL             -Value '.kilocode\skills'
Set-Variable -Option Constant -Name OPENCODE_SKILLS_REL         -Value '.opencode\commands'
# OpenCode plugin: TypeScript whole-file ownership. Both scopes diverge
# on directory (`.opencode\plugins\` vs `.config\opencode\plugins\`).
Set-Variable -Option Constant -Name OPENCODE_CONFIG_REL          -Value '.opencode\plugins'
Set-Variable -Option Constant -Name OPENCODE_USER_CONFIG_REL     -Value '.config\opencode\plugins'
Set-Variable -Option Constant -Name PI_SKILLS_REL               -Value '.agents\skills'
# Pi extension: TypeScript whole-file ownership (same install branch
# as OpenCode). User scope nests inside `.pi\agent\`.
Set-Variable -Option Constant -Name PI_CONFIG_REL                -Value '.pi\extensions'
Set-Variable -Option Constant -Name PI_USER_CONFIG_REL           -Value '.pi\agent\extensions'
Set-Variable -Option Constant -Name ZED_SKILLS_REL              -Value '.agents\skills'

# Local-server constants — mirrors of serverListenAddr / serverDisplayURL
# / apiStatsPath / apiSystemsPath in constants.go. Bare `stax` starts an
# HTTP listener on serverListenAddr; the Windows e2e spawns it in the
# background and probes these paths the same way the bash harness does.
Set-Variable -Option Constant -Name STAX_SERVER_LISTEN_ADDR -Value '127.0.0.1:7829'
Set-Variable -Option Constant -Name STAX_SERVER_DISPLAY_URL -Value 'http://localhost:7829'
Set-Variable -Option Constant -Name STAX_API_STATS_PATH     -Value '/api/stats'
Set-Variable -Option Constant -Name STAX_API_SYSTEMS_PATH   -Value '/api/systems'

# Bundled config filenames (not constants in Go; pinned here for assertions).
Set-Variable -Option Constant -Name CLAUDE_SETTINGS_FILE -Value 'settings.json'
Set-Variable -Option Constant -Name CODEX_HOOKS_FILE     -Value 'hooks.json'

Set-Variable -Option Constant -Name E2E_VERSION -Value 'v0.0.0-e2e'

# Compositions so call sites read as plain English.
$Script:STAX_AGENTS_DIR        = Join-Path $STAX_DIR    $AGENTS_EMBED_ROOT
$Script:STAX_AGENTS_SKILLS_DIR = Join-Path $STAX_AGENTS_DIR  $SKILLS_SUBDIR
$Script:STAX_LOCK_PATH      = Join-Path $STAX_DIR      $STAX_LOCK_FILE
$Script:STAX_SYSTEMS_PATH   = Join-Path $STAX_DIR      $STAX_SYSTEMS_FILE
$Script:CLAUDE_SETTINGS_PATH = Join-Path $CLAUDE_CONFIG_REL $CLAUDE_SETTINGS_FILE
$Script:CODEX_HOOKS_PATH     = Join-Path $CODEX_CONFIG_REL  $CODEX_HOOKS_FILE

# ---------- locations ----------

$Script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$Script:Sandbox  = Join-Path ([System.IO.Path]::GetTempPath()) "stax-e2e-$([guid]::NewGuid())"
# Build artifact lives inside the sandbox so nothing lands in the repo's
# working tree. The sandbox is wiped on exit via the trap below.
$Script:BuildBin = Join-Path $Sandbox 'stax-e2e.exe'

New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null

# Sandbox HOME mirrors the bash harness's pattern: we only pivot HOME/USERPROFILE
# AFTER the build step so `go build` keeps using the developer's real module
# cache instead of repopulating one inside the sandbox.
$Script:SandboxHome  = Join-Path $Sandbox 'home'
$Script:ProjectsRoot = Join-Path $Sandbox 'projects'
New-Item -ItemType Directory -Force -Path $SandboxHome  | Out-Null
New-Item -ItemType Directory -Force -Path $ProjectsRoot | Out-Null

# Suppress anonymous-usage telemetry for the entire e2e run — same
# rationale as the bash harness. DO_NOT_TRACK is industry-standard;
# DISABLE_TELEMETRY is the project-specific belt-and-braces escape
# hatch.
$env:DO_NOT_TRACK     = '1'
$env:DISABLE_TELEMETRY = '1'

# Cleanup must tolerate read-only files (e.g. Go module cache the test might
# have populated). attrib -r is best-effort; Remove-Item -Force always runs.
function Invoke-Cleanup {
  if (Test-Path -LiteralPath $Sandbox) {
    Get-ChildItem -Recurse -Force -LiteralPath $Sandbox -ErrorAction SilentlyContinue |
      ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
    Remove-Item -Recurse -Force -LiteralPath $Sandbox -ErrorAction SilentlyContinue
  }
}

# Trap-equivalent: register cleanup that runs even on uncaught exception.
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Invoke-Cleanup } | Out-Null

# ---------- pretty + assertion helpers ----------

$Script:PassCount   = 0
$Script:FailCount   = 0
$Script:SkipCount   = 0
$Script:CurrentCase = ''

function Start-Case {
  param([Parameter(Mandatory)][string]$Name)
  $Script:CurrentCase = $Name
  Write-Host ''
  Write-Host "=== $Name ==="
}

function Write-Pass {
  param([Parameter(Mandatory)][string]$Label)
  $Script:PassCount++
  Write-Host "  ok   $Label"
}

# Write-Skip surfaces a case that didn't run because a host-level capability
# was unavailable (8.3 short-path generation, LongPathsEnabled, etc.). Skips
# are visible in the log AND counted in the final summary so a runner-config
# regression that suddenly turns off a feature shows up as "skips ticked up"
# rather than silently shrinking coverage. NOT for assertion bypass — use
# Write-Pass or Write-Fail for that.
function Write-Skip {
  param([Parameter(Mandatory)][string]$Reason)
  $Script:SkipCount++
  Write-Host "  skip $Reason" -ForegroundColor Yellow
}

function Write-Fail {
  param(
    [Parameter(Mandatory)][string]$Label,
    [string]$Detail = ''
  )
  $Script:FailCount++
  Write-Host "  FAIL $Label" -ForegroundColor Red
  if ($Detail) { Write-Host "       $Detail" -ForegroundColor Red }
  # Always surface the last Invoke-XX context on a failure. Even when the
  # assertion didn't directly test stdout/stderr (e.g. it asserted an exit
  # code), the captured streams are usually the first thing the human needs
  # to diagnose. Without this, `got=[2] want=[0]` is opaque.
  if ($Script:LastCmd) {
    Write-Host ("       last cmd : " + $Script:LastCmd)        -ForegroundColor Yellow
    Write-Host ("       last rc  : " + $Script:RunRC)          -ForegroundColor Yellow
    if ($Script:RunOut) { Write-Host ("       last out : " + $Script:RunOut) -ForegroundColor Yellow }
    if ($Script:RunErr) { Write-Host ("       last err : " + $Script:RunErr) -ForegroundColor Yellow }
  }
}

function Assert-Eq {
  param(
    [Parameter(Mandatory)][string]$Label,
    [object]$Got,
    [object]$Want
  )
  # -ceq is case-sensitive on strings; integers compare by value either way.
  if ($Got -is [string] -and $Want -is [string]) {
    $equal = ($Got -ceq $Want)
  } else {
    $equal = ($Got -eq $Want)
  }
  if ($equal) {
    Write-Pass $Label
  } else {
    Write-Fail $Label "got=[$Got] want=[$Want]"
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory)][string]$Label,
    [string]$Haystack,
    [Parameter(Mandatory)][string]$Needle
  )
  if ($Haystack -and $Haystack.Contains($Needle)) {
    Write-Pass $Label
  } else {
    Write-Fail $Label "needle [$Needle] not in: $Haystack"
  }
}

function Assert-NotContains {
  param(
    [Parameter(Mandatory)][string]$Label,
    [string]$Haystack,
    [Parameter(Mandatory)][string]$Needle
  )
  if (-not $Haystack -or -not $Haystack.Contains($Needle)) {
    Write-Pass $Label
  } else {
    Write-Fail $Label "unexpected needle [$Needle] in: $Haystack"
  }
}

function Assert-IsFile {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Path
  )
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    Write-Pass $Label
  } else {
    Write-Fail $Label "file not found: $Path"
  }
}

function Assert-IsDir {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Path
  )
  if (Test-Path -LiteralPath $Path -PathType Container) {
    Write-Pass $Label
  } else {
    Write-Fail $Label "directory not found: $Path"
  }
}

function Assert-NotExists {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Pass $Label
  } else {
    Write-Fail $Label "unexpected path present: $Path"
  }
}

# Symlinks on Windows require either Developer Mode, admin elevation, or
# SeCreateSymbolicLinkPrivilege. stax's install path falls back to a copy
# on Windows for exactly this reason, so the assertion here checks for the
# COPY form (regular file/dir, no LinkType) — the inverse of the macOS
# user-scope assertion in the bash e2e.
function Assert-IsCopyNotSymlink {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Fail $Label "path not found: $Path"
    return
  }
  $item = Get-Item -LiteralPath $Path -Force
  if ($null -eq $item.LinkType) {
    Write-Pass $Label
  } else {
    Write-Fail $Label "expected a copy, got a $($item.LinkType) link at: $Path"
  }
}

# ---------- stax runner ----------
#
# Mirrors the bash harness's `run_capture <stdin> <args...>`. Stores the
# captured stdout/stderr/exit code in $Script:RunOut / $Script:RunErr /
# $Script:RunRC so per-case assertions read like the bash form.
#
# IMPORTANT: `Invoke-XX` is a deliberately NON-advanced function (no
# `[CmdletBinding()]`, no `param()` block). PowerShell's parameter binder
# rules:
#   - Any declared parameter without a Position attribute becomes positional
#     in declaration order — so a `[string]$Stdin` would silently swallow
#     the first positional arg from every call site. That's the bug the
#     earlier draft hit; every `Invoke-XX frobnicate` bound 'frobnicate'
#     to $Stdin and ran the exe with no args.
#   - The `--` end-of-parameters marker is ALWAYS consumed/stripped by the
#     binder, in both advanced and non-advanced functions, with no opt-out
#     (PowerShell/PowerShell#21208). So we can't rely on it either.
#   - In a non-advanced function with NO declared parameters, every arg —
#     including hyphen-prefixed `--scope` / `--prefix-width` — falls through
#     to the `$args` automatic variable verbatim. That's exactly what we
#     want for forwarding to the native exe.
#
# Stdin is supplied out-of-band via the script-scope variable
# `$Script:NextStdin` so it doesn't have to share the positional channel.
# Tests that don't feed stdin leave it $null; tests that do set it
# immediately before calling Invoke-XX. The helper consumes it one-shot
# (resets to $null on entry) so a stale value can't leak into the next call.
#
# Invocation uses the `&` call operator with `@args` splat — pwsh 7+ passes
# each array element as a distinct argv entry, preserving quoting / spaces /
# embedded tabs without the lossy joining behavior of
# `Start-Process -ArgumentList`. `> file 2> file` redirection preserves byte
# streams since pwsh 7.4; we deliberately AVOID `2>&1` because it triggers
# NativeCommandError wrapping that fights with $ErrorActionPreference='Stop'.

$Script:RunOut    = ''
$Script:RunErr    = ''
$Script:RunRC     = 0
$Script:NextStdin = $null
$Script:LastCmd   = ''  # for Write-Fail diagnostics

function Invoke-XX {
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  $stdin  = $Script:NextStdin
  $Script:NextStdin = $null  # one-shot consumption
  # Snapshot the command line so Write-Fail can include it in diagnostics.
  $Script:LastCmd = "stax " + ($args -join ' ')
  if ($null -ne $stdin -and $stdin -ne '') {
    $Script:LastCmd += "  (stdin: " + ($stdin -replace '`r', '\\r' -replace '`n', '\\n') + ')'
  }
  try {
    if ($null -ne $stdin -and $stdin -ne '') {
      $stdin | & $Script:BuildBin @args > $tmpOut 2> $tmpErr
    } else {
      & $Script:BuildBin @args > $tmpOut 2> $tmpErr
    }
    $Script:RunRC  = $LASTEXITCODE
    $Script:RunOut = Get-Content -Raw -LiteralPath $tmpOut -ErrorAction SilentlyContinue
    $Script:RunErr = Get-Content -Raw -LiteralPath $tmpErr -ErrorAction SilentlyContinue
    if ($null -eq $Script:RunOut) { $Script:RunOut = '' }
    if ($null -eq $Script:RunErr) { $Script:RunErr = '' }
    $Script:RunOut = $Script:RunOut -replace '\r?\n$', ''
    $Script:RunErr = $Script:RunErr -replace '\r?\n$', ''
  } finally {
    Remove-Item -Force -LiteralPath $tmpOut -ErrorAction SilentlyContinue
    Remove-Item -Force -LiteralPath $tmpErr -ErrorAction SilentlyContinue
  }
  if ($Script:VerboseMode) {
    Write-Host ("  [verbose] cmd : " + $Script:LastCmd)
    Write-Host ("  [verbose] rc  : " + $Script:RunRC)
    if ($Script:RunOut) { Write-Host ("  [verbose] out : " + $Script:RunOut) }
    if ($Script:RunErr) { Write-Host ("  [verbose] err : " + $Script:RunErr) }
  }
}

# ---------- project / home helpers ----------

function Start-StaxServer {
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs = @()
  )
  # Bare `stax` blocks on the loopback HTTP server. Start it in the
  # background, wait up to 5s for the listening banner to appear in
  # stdout (which carries the actually-bound URL — preferred port may
  # have been busy and the server fell forward to an adjacent one per
  # `serverPortFallbackAttempts`), then probe `/api/stats` against that
  # URL. Returns the Process object with `StaxStdout`, `StaxStderr`,
  # and `StaxUrl` properties attached for the caller. On timeout, dumps
  # stdout/stderr into the exception message so CI runs can self-
  # diagnose without re-running with debug logging.
  $stdout = New-TemporaryFile
  $stderr = New-TemporaryFile
  $args = @($ExtraArgs)
  $proc = Start-Process -FilePath $BuildBin -ArgumentList $args `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdout.FullName `
    -RedirectStandardError  $stderr.FullName
  Add-Member -InputObject $proc -NotePropertyName StaxStdout   -NotePropertyValue $stdout.FullName -Force
  Add-Member -InputObject $proc -NotePropertyName StaxStderr   -NotePropertyValue $stderr.FullName -Force
  Add-Member -InputObject $proc -NotePropertyName StaxUrl      -NotePropertyValue ''                -Force
  Add-Member -InputObject $proc -NotePropertyName StaxProbeUrl -NotePropertyValue ''                -Force
  $deadline = (Get-Date).AddSeconds(5)
  $bannerRe = 'Stax server listening on (\S+)'
  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
      $out = Get-Content -LiteralPath $stdout.FullName -Raw -ErrorAction SilentlyContinue
      $err = Get-Content -LiteralPath $stderr.FullName -Raw -ErrorAction SilentlyContinue
      throw "stax background process exited before listening (rc=$($proc.ExitCode))`nstdout: $out`nstderr: $err"
    }
    $banner = Get-Content -LiteralPath $stdout.FullName -Raw -ErrorAction SilentlyContinue
    if ($banner -and ($banner -match $bannerRe)) {
      $proc.StaxUrl = $matches[1]
      # serverListenAddr binds 127.0.0.1 (IPv4 only). The banner prints
      # `http://localhost:<port>`, but Windows' resolver returns `::1`
      # for `localhost` first, and Invoke-WebRequest sits there timing
      # out against an IPv6 endpoint nothing is listening on. Probe via
      # the IPv4 literal while keeping the banner URL untouched for
      # banner-content assertions. Linux's resolver already prefers
      # IPv4 for localhost so the bash harness sidesteps this.
      $proc.StaxProbeUrl = $proc.StaxUrl -replace 'http://localhost(:|/|$)', 'http://127.0.0.1$1'
      try {
        $null = Invoke-WebRequest -Uri "$($proc.StaxProbeUrl)$STAX_API_STATS_PATH" `
          -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
        return $proc
      } catch {
        # Banner present but probe failed — keep retrying within the
        # deadline (server may still be wiring routes).
      }
    }
    Start-Sleep -Milliseconds 100
  }
  $out = Get-Content -LiteralPath $stdout.FullName -Raw -ErrorAction SilentlyContinue
  $err = Get-Content -LiteralPath $stderr.FullName -Raw -ErrorAction SilentlyContinue
  Stop-StaxServer -Process $proc
  throw "stax server never started listening (deadline 5s)`nstdout: $out`nstderr: $err"
}

function Stop-StaxServer {
  param(
    [Parameter(Mandatory)][System.Diagnostics.Process]$Process
  )
  # SIGTERM-equivalent on Windows is Process.CloseMainWindow (graceful) or
  # Kill (hard). The Go server's signal.Notify catches os.Interrupt — which
  # the PowerShell `Stop-Process` (TerminateProcess under the hood) does
  # NOT translate into. To exercise graceful shutdown reliably we'd need
  # to attach to a console and send Ctrl-C; for the test we just hard-kill
  # so the process always reaps. The handlers don't hold persistent state,
  # so a kill is safe.
  if (-not $Process.HasExited) {
    try { $Process.Kill() } catch {}
  }
  $Process.WaitForExit()
  if ($Process.PSObject.Properties.Match('StaxStdout').Count -gt 0) {
    Remove-Item -LiteralPath $Process.StaxStdout -ErrorAction SilentlyContinue
  }
  if ($Process.PSObject.Properties.Match('StaxStderr').Count -gt 0) {
    Remove-Item -LiteralPath $Process.StaxStderr -ErrorAction SilentlyContinue
  }
}

function Reset-UserHome {
  if (Test-Path -LiteralPath $SandboxHome) {
    Get-ChildItem -Recurse -Force -LiteralPath $SandboxHome -ErrorAction SilentlyContinue |
      ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
    Remove-Item -Recurse -Force -LiteralPath $SandboxHome -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path $SandboxHome | Out-Null
  # Both env vars are read by `os.UserHomeDir()` depending on the platform;
  # Windows uses USERPROFILE, but some Go paths also consult HOME. Set both.
  $env:HOME        = $SandboxHome
  $env:USERPROFILE = $SandboxHome
}

function New-FreshProject {
  $name = "proj-$([guid]::NewGuid().ToString().Substring(0, 8))"
  $path = Join-Path $ProjectsRoot $name
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  return $path
}

# Seeds a project scaffold the way `stax init --scope project` would: planDir
# with a syntactically-valid lock file and an empty systems registry. Tests
# that need a "fully initialized" project-marker check to pass use this rather than
# running real init (which we test separately).
function Initialize-ProjectScaffold {
  param([Parameter(Mandatory)][string]$Path)
  $planDir = Join-Path $Path $STAX_DIR
  New-Item -ItemType Directory -Force -Path $planDir | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $planDir $STAX_SYSTEMS_FILE) | Out-Null
  $lockJson = @"
{
  "prefix_width": $DEFAULT_PREFIX_WIDTH,
  "max_work_item_lines": 30,
  "review_per": "task"
}
"@
  Set-Content -LiteralPath (Join-Path $planDir $STAX_LOCK_FILE) -Value $lockJson -Encoding ascii
}

# Zero-padded prefix helper — mirrors the bash `prefix WIDTH N`. Used by every
# work-item-file fixture in the work-items-list/work-items-lint sections.
function Format-Prefix {
  param(
    [int]$Width,
    [int]$N
  )
  return $N.ToString().PadLeft($Width, '0')
}

# Writes a minimally-valid work-item file (frontmatter + body) for use by tests
# that exercise `work-items list`. Body is the third positional so cases can
# override per test.
function Write-Plan {
  param(
    [Parameter(Mandatory)][string]$StaxDir,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][string]$Systems   # comma-separated kebab ids
  )
  $title = ($Name -replace '\.md$', '') -replace '^\d+-', ''
  $fm = @"
---
title: $title
status: $Status
systems: [$Systems]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do a thing.
"@
  $fullPath = Join-Path $StaxDir $Name
  Set-Content -LiteralPath $fullPath -Value $fm -Encoding ascii
}

# Writes the systems registry with the requested comma-separated display
# names. Each name's kebab id is derived by lowercase + space→hyphen.
function Write-Registry {
  param(
    [Parameter(Mandatory)][string]$StaxDir,
    [Parameter(Mandatory)][string]$Names   # "Auth Service,Billing Service"
  )
  $lines = @('systems:')
  foreach ($name in $Names.Split(',')) {
    $trimmed = $name.Trim()
    if (-not $trimmed) { continue }
    $id = $trimmed.ToLowerInvariant() -replace '\s+', '-'
    $lines += "  - id: $id"
    $lines += "    name: $trimmed"
    $lines += "    brief: seeded by e2e harness"
  }
  $body = ($lines -join "`n") + "`n"
  Set-Content -LiteralPath (Join-Path $StaxDir $STAX_SYSTEMS_FILE) -Value $body -Encoding ascii
}

# ---------- build ----------

# server.go embeds `frontend/dist/` via `//go:embed all:frontend/dist`. The
# dist tree is gitignored, so a fresh clone has nothing for the embed to
# match and `go build` fails with "pattern all:frontend/dist: no matching
# files". CI builds dist in a separate workflow step
# (.github/workflows/windows-cli.yml mirrors the Linux test workflow on
# this) but the lefthook pre-push hook calls this script directly — so
# we bootstrap dist here when it's missing. Already-built trees are left
# untouched to keep local re-runs fast; set $env:FORCE_FRONTEND_BUILD=1
# to rebuild unconditionally.
$frontendDist = Join-Path $RepoRoot 'frontend\dist'
if ($env:FORCE_FRONTEND_BUILD -eq '1' -or -not (Test-Path -LiteralPath $frontendDist -PathType Container)) {
  Write-Host 'Building frontend/dist (for //go:embed all:frontend/dist)...'
  Push-Location (Join-Path $RepoRoot 'frontend')
  try {
    if (-not (Test-Path -LiteralPath 'node_modules' -PathType Container)) {
      & npm ci
      if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE" }
    }
    & npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
  if (-not (Test-Path -LiteralPath $frontendDist -PathType Container)) {
    throw "expected frontend/dist after npm run build, not found at $frontendDist"
  }
} else {
  Write-Host 'frontend/dist already present (skipping build; set $env:FORCE_FRONTEND_BUILD=1 to override).'
}

Write-Host "Building $($Script:BuildBin) (release-flavored, CGO disabled)..."
Push-Location $RepoRoot
try {
  $env:CGO_ENABLED = '0'
  & go build -ldflags "-s -w -X main.Version=$E2E_VERSION" -o $Script:BuildBin .
  if ($LASTEXITCODE -ne 0) {
    throw "go build failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

# Now that the build is done, pivot HOME so every subsequent stax invocation
# writes into the sandbox instead of the developer's real user profile.
Reset-UserHome

if (-not (Test-Path -LiteralPath $Script:BuildBin -PathType Leaf)) {
  throw "expected build artifact not found: $($Script:BuildBin)"
}

Write-Host "Sandbox: $Sandbox"
Write-Host "Binary:  $($Script:BuildBin)"
Write-Host ''

# ==========================================================================
# Test cases
# ==========================================================================

# ---------- bare invocation ----------

Start-Case 'stax post-install seeds agents silently'
Reset-UserHome
Invoke-XX post-install
Assert-Eq       'exit 0'    $RunRC 0
Assert-Eq       'no stdout' $RunOut ''
Assert-Eq       'no stderr' $RunErr ''
$agentsDir = Join-Path $env:USERPROFILE $STAX_AGENTS_DIR
Assert-IsDir   'agents tree present' $agentsDir
Assert-IsDir   'skills subdir'       (Join-Path $env:USERPROFILE $STAX_AGENTS_SKILLS_DIR)
foreach ($skill in $OWNED_SKILLS) {
  Assert-IsDir "bundled skill $skill" (Join-Path $env:USERPROFILE (Join-Path $STAX_AGENTS_SKILLS_DIR $skill))
}
Assert-IsFile  'stax SKILL.md'    (Join-Path $env:USERPROFILE (Join-Path $STAX_AGENTS_SKILLS_DIR (Join-Path $SKILL_SHIP_DIR $SKILL_MANIFEST_FILE)))
Assert-IsFile  'scope SKILL.md' (Join-Path $env:USERPROFILE (Join-Path $STAX_AGENTS_SKILLS_DIR (Join-Path $SKILL_SCOPE_DIR $SKILL_MANIFEST_FILE)))
Assert-NotExists 'embed README skipped from disk' (Join-Path $env:USERPROFILE (Join-Path $STAX_AGENTS_DIR 'README.md'))

# Bare `stax` on Windows now launches a loopback HTTP server on
# 127.0.0.1:7829 instead of opening the OS-default browser. CI runners
# don't want browser windows spawning mid-test, so cases that exercise
# the server pass --no-browser (which keeps the server running but
# suppresses the rundll32 handoff). For the idempotency / lazy-bootstrap
# cases that don't care about the listener we use --version: it fires
# ensureBundledAgents + maybeNotifyUpdate and exits cleanly.

Start-Case 'stax --no-browser starts the loopback API server'
Reset-UserHome
$projNoBrowser = New-FreshProject
Initialize-ProjectScaffold -Path $projNoBrowser
$srv = Start-StaxServer --no-browser --cwd $projNoBrowser
try {
  $resp = Invoke-WebRequest -Uri "$($srv.StaxProbeUrl)$STAX_API_STATS_PATH" -TimeoutSec 1 -UseBasicParsing
  Assert-Eq       'stats status 200' $resp.StatusCode 200
  Assert-Contains 'stats version'    $resp.Content "`"version`":`"$E2E_VERSION`""
  Assert-Contains 'stats systems'    $resp.Content '"systems":'
  Assert-Contains 'stats workItems'     $resp.Content '"workItems":'
  $banner = Get-Content -LiteralPath $srv.StaxStdout -Raw
  Assert-Contains 'listening banner' $banner $srv.StaxUrl
  Assert-Contains 'ctrl-c hint'      $banner 'Ctrl-C'
  $errOut = Get-Content -LiteralPath $srv.StaxStderr -Raw -ErrorAction SilentlyContinue
  if ($null -eq $errOut) { $errOut = '' }
  Assert-NotContains 'no browser warning' $errOut 'could not open browser'
} finally {
  Stop-StaxServer -Process $srv
}
Assert-IsDir 'lazy-bootstrap agents tree present' (Join-Path $env:USERPROFILE $STAX_AGENTS_DIR)

# Bare `stax` (and `stax --no-browser`) gates on .stax/_config.lock so
# the UI never spawns against a directory it cannot read scopes from.
# A missing marker MUST emit the canonical `stax init` banner on
# stderr, exit 2 (usage error), and skip the listener / browser open
# entirely.
Start-Case 'stax --cwd <not-a-project> prints init banner and exits 2'
Reset-UserHome
$noProjBare = New-FreshProject
Invoke-XX --no-browser --cwd $noProjBare
Assert-Eq       'exit 2'         $RunRC  2
Assert-Eq       'no stdout'      $RunOut ''
Assert-Contains 'init-banner'    $RunErr 'not a stax project'
Assert-Contains 'init-banner'    $RunErr 'stax init'

Start-Case 'stax --cwd <PROJ> serves /api/systems for that project'
Reset-UserHome
$projApi = New-FreshProject
Initialize-ProjectScaffold -Path $projApi
$registry = "systems:`n  - id: auth`n    name: Auth Service`n"
Set-Content -LiteralPath (Join-Path (Join-Path $projApi $STAX_DIR) $STAX_SYSTEMS_FILE) -Value $registry -Encoding ascii
$srv = Start-StaxServer --no-browser --cwd $projApi
try {
  $resp = Invoke-WebRequest -Uri "$($srv.StaxProbeUrl)$STAX_API_SYSTEMS_PATH" -TimeoutSec 1 -UseBasicParsing
  Assert-Eq       'systems status 200' $resp.StatusCode 200
  Assert-Contains 'systems id'          $resp.Content '"id":"auth"'
  Assert-Contains 'systems name'        $resp.Content '"name":"Auth Service"'
} finally {
  Stop-StaxServer -Process $srv
}

Start-Case 'stax --cwd <empty-project> serves /api/systems as empty list'
Reset-UserHome
$emptyProjApi = New-FreshProject
Initialize-ProjectScaffold -Path $emptyProjApi
Remove-Item -LiteralPath (Join-Path (Join-Path $emptyProjApi $STAX_DIR) $STAX_SYSTEMS_FILE) -ErrorAction SilentlyContinue
$srv = Start-StaxServer --no-browser --cwd $emptyProjApi
try {
  $resp = Invoke-WebRequest -Uri "$($srv.StaxProbeUrl)$STAX_API_SYSTEMS_PATH" -TimeoutSec 1 -UseBasicParsing
  Assert-Eq       'systems status 200'  $resp.StatusCode 200
  Assert-Contains 'empty systems list'  $resp.Content '"systems":[]'
} finally {
  Stop-StaxServer -Process $srv
}

Start-Case 'stax --version is idempotent (second run does not re-bootstrap)'
Reset-UserHome
Invoke-XX --version
Assert-Eq    'first --version exit 0' $RunRC 0
$sentinel = Join-Path $env:USERPROFILE (Join-Path $STAX_AGENTS_SKILLS_DIR (Join-Path $SKILL_SHIP_DIR $SKILL_MANIFEST_FILE))
$firstMtime = (Get-Item -LiteralPath $sentinel).LastWriteTimeUtc
Start-Sleep -Seconds 1
Invoke-XX --version
$secondMtime = (Get-Item -LiteralPath $sentinel).LastWriteTimeUtc
Assert-Eq 'mtime unchanged across runs' $firstMtime $secondMtime

Start-Case 'stax --version prints the notice'
Invoke-XX --version
Assert-Eq       'exit 0'          $RunRC 0
Assert-Contains 'version line'    $RunOut 'Stax by Stackific'
Assert-Contains 'version stamp'   $RunOut $E2E_VERSION
Assert-Contains 'product tagline' $RunOut 'evidence-based'
Assert-Contains 'copyright line'  $RunOut 'Copyright 2026 Stackific Inc.'
Assert-Contains 'SPDX line'       $RunOut 'Apache-2.0'

Start-Case 'stax -h prints the usage block'
Invoke-XX -h
Assert-Eq       'exit 0'                       $RunRC 0
Assert-Contains 'usage header'                 $RunOut 'Usage:'
Assert-Contains 'no-browser listed'            $RunOut '--no-browser'
Assert-Contains 'post-install listed'          $RunOut 'stax post-install'
Assert-Contains 'init listed'                  $RunOut 'stax init'
Assert-Contains 'skills remove --user listed'  $RunOut 'stax skills remove --user'
Assert-Contains 'skills remove --project listed' $RunOut 'stax skills remove --project'
Assert-Contains 'work-items next-prefix listed'     $RunOut 'stax work-items next-prefix'
Assert-Contains 'work-items list listed'            $RunOut 'stax work-items list'
Assert-Contains 'work-items lint listed'            $RunOut 'stax work-items lint'
Assert-Contains 'work-items slugify listed'         $RunOut 'stax work-items slugify'
Assert-Contains 'cwd flag listed'              $RunOut '--cwd <path>'
# Help text MUST NOT leak server internals — the HTTP routes and the
# listen URL are implementation details behind the web UI, not user
# surfaces.
Assert-NotContains 'no api stats leak'         $RunOut $STAX_API_STATS_PATH
Assert-NotContains 'no api systems leak'       $RunOut $STAX_API_SYSTEMS_PATH
Assert-NotContains 'no listen url leak'        $RunOut $STAX_SERVER_DISPLAY_URL

Start-Case 'unknown subcommand exits 2 with diagnostic'
Invoke-XX frobnicate
Assert-Eq       'exit 2'     $RunRC 2
Assert-Contains 'diagnostic' $RunErr 'unknown subcommand: frobnicate'

# ---------- skills subcommand routing ----------

Start-Case 'stax skills (no subcommand) prints usage to stderr and exits 2'
Invoke-XX skills
Assert-Eq       'exit 2'        $RunRC 2
Assert-Contains 'usage header'  $RunErr 'Usage: stax skills <subcommand>'
Assert-Contains 'remove --user' $RunErr 'remove --user'

Start-Case 'stax skills <typo> exits 2 with diagnostic'
Invoke-XX skills frobnicate
Assert-Eq       'exit 2'     $RunRC 2
Assert-Contains 'diagnostic' $RunErr 'unknown skills subcommand: frobnicate'

Start-Case 'stax skills remove (no flag) prints usage and exits 2'
Invoke-XX skills remove
Assert-Eq       'exit 2'       $RunRC 2
Assert-Contains 'usage header' $RunErr 'Usage: stax skills remove'

Start-Case 'stax skills remove --user --project rejects mutually-exclusive flags'
Invoke-XX skills remove --user --project
Assert-Eq       'exit 2'     $RunRC 2
Assert-Contains 'diagnostic' $RunErr 'mutually exclusive'

# ---------- work-items subcommand routing ----------

Start-Case 'stax work-items (no subcommand) prints usage to stderr and exits 2'
Invoke-XX work-items
Assert-Eq       'exit 2'       $RunRC 2
Assert-Contains 'usage header' $RunErr 'Usage: stax work-items <subcommand>'
Assert-Contains 'next-prefix'  $RunErr 'next-prefix'
Assert-Contains 'list'         $RunErr 'list'
Assert-Contains 'lint'         $RunErr 'lint'
Assert-Contains 'slugify'      $RunErr 'slugify'

Start-Case 'stax work-items <typo> exits 2 with diagnostic'
Invoke-XX work-items frobnicate
Assert-Eq       'exit 2'     $RunRC 2
Assert-Contains 'diagnostic' $RunErr 'unknown work-items subcommand: frobnicate'

# ---------- work-items slugify (no project-marker check) ----------

Start-Case 'work-items slugify lowercases ASCII'
Invoke-XX work-items slugify 'Add Payment Retry'
Assert-Eq 'exit 0'      $RunRC 0
Assert-Eq 'slug printed' $RunOut 'add-payment-retry'

Start-Case 'work-items slugify collapses runs of non-alnum'
Invoke-XX work-items slugify 'foo!!!bar---baz'
Assert-Eq 'exit 0'      $RunRC 0
Assert-Eq 'slug printed' $RunOut 'foo-bar-baz'

Start-Case 'work-items slugify trims leading/trailing dashes'
Invoke-XX work-items slugify '---foo---'
Assert-Eq 'exit 0'       $RunRC 0
Assert-Eq 'slug printed' $RunOut 'foo'

Start-Case 'work-items slugify accepts a double-dash-prefixed title WITHOUT --'
# runPlansSlugify bypasses flag.Parse so `--draft note` is treated as the
# title verbatim, not as a flag. Without that fix, flag.Parse would reject
# this with "flag provided but not defined: -draft".
Invoke-XX work-items slugify '--draft note'
Assert-Eq 'exit 0'         $RunRC 0
Assert-Eq 'double-dash slug' $RunOut 'draft-note'

Start-Case 'work-items slugify accepts pure numerics'
Invoke-XX work-items slugify '12345'
Assert-Eq 'exit 0'       $RunRC 0
Assert-Eq 'numeric slug' $RunOut '12345'

Start-Case 'work-items slugify rejects missing argument'
Invoke-XX work-items slugify
Assert-Eq       'exit 2'     $RunRC 2
Assert-Contains 'diagnostic' $RunErr 'takes exactly one positional argument'

Start-Case 'work-items slugify rejects multiple positional arguments'
Invoke-XX work-items slugify foo bar
Assert-Eq       'exit 2'     $RunRC 2
Assert-Contains 'diagnostic' $RunErr 'takes exactly one positional argument'

Start-Case 'work-items slugify rejects an unsluggable title'
Invoke-XX work-items slugify '!!! ??? ###'
Assert-Eq       'exit 2'     $RunRC 2
Assert-Contains 'diagnostic' $RunErr 'no slug-able characters'

Start-Case 'work-items slugify works outside a stax project'
$noProject = New-FreshProject
Push-Location $noProject
try {
  Invoke-XX work-items slugify 'Some Title'
  Assert-Eq 'exit 0'       $RunRC 0
  Assert-Eq 'slug printed' $RunOut 'some-title'
} finally { Pop-Location }

# ---------- project-marker check ----------

Start-Case 'work-items next-prefix in non-project exits 2 with diagnostic'
$noProj = New-FreshProject
Push-Location $noProj
try {
  Invoke-XX work-items next-prefix
  Assert-Eq       'exit 2'     $RunRC 2
  Assert-Contains 'diagnostic' $RunErr 'not a stax project'
} finally { Pop-Location }

Start-Case 'work-items list in non-project exits 2 with diagnostic'
Push-Location $noProj
try {
  Invoke-XX work-items list
  Assert-Eq       'exit 2'     $RunRC 2
  Assert-Contains 'diagnostic' $RunErr 'not a stax project'
} finally { Pop-Location }

Start-Case 'work-items lint in non-project exits 2 with diagnostic'
Push-Location $noProj
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 2'     $RunRC 2
  Assert-Contains 'diagnostic' $RunErr 'not a stax project'
} finally { Pop-Location }

Start-Case 'project-marker-check diagnostic does not leak internal path components'
Push-Location $noProj
try {
  Invoke-XX work-items list
  Assert-NotContains 'no .stax/ leak'      $RunErr $STAX_DIR
  Assert-NotContains 'no lock file leak'     $RunErr $STAX_LOCK_FILE
  Assert-NotContains 'no registry file leak' $RunErr $STAX_SYSTEMS_FILE
} finally { Pop-Location }

# ---------- work-items next-prefix ----------

Start-Case 'work-items next-prefix returns the zero-padded first prefix on a fresh project'
$proj = New-FreshProject
Initialize-ProjectScaffold $proj
Push-Location $proj
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0'        $RunRC 0
  Assert-Eq 'first prefix'  $RunOut '0001'
} finally { Pop-Location }

Start-Case 'work-items next-prefix walks past existing work items'
$projB = New-FreshProject
Initialize-ProjectScaffold $projB
$staxDir = Join-Path $projB $STAX_DIR
Write-Plan $staxDir '0003-charlie.md' 'valid' 'auth-service'
Write-Plan $staxDir '0005-echo.md'    'valid' 'auth-service'
Write-Plan $staxDir '0002-bravo.md'   'valid' 'auth-service'
Push-Location $projB
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0'           $RunRC 0
  Assert-Eq 'next after 0005' $RunOut '0006'
} finally { Pop-Location }

Start-Case 'work-items next-prefix honors prefix_width pin from _config.lock'
$projC = New-FreshProject
Initialize-ProjectScaffold $projC
$lockC = Join-Path (Join-Path $projC $STAX_DIR) $STAX_LOCK_FILE
Set-Content -LiteralPath $lockC -Value '{"prefix_width":6,"max_work_item_lines":30,"review_per":"task"}' -Encoding ascii
Push-Location $projC
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0'             $RunRC 0
  Assert-Eq '6-wide first prefix' $RunOut '000001'
} finally { Pop-Location }

Start-Case 'work-items next-prefix rejects positional arguments'
Push-Location $proj
try {
  Invoke-XX work-items next-prefix extra
  Assert-Eq       'exit 2'     $RunRC 2
  Assert-Contains 'diagnostic' $RunErr 'takes no arguments'
} finally { Pop-Location }

# ---------- work-items list ----------

Start-Case 'work-items list emits tab-separated rows sorted by prefix descending (default)'
$projL = New-FreshProject
Initialize-ProjectScaffold $projL
$staxDirL = Join-Path $projL $STAX_DIR
Write-Plan $staxDirL '0002-bravo.md'   'deprecated' 'billing'
Write-Plan $staxDirL '0001-alpha.md'   'valid'      'auth,billing'
Write-Plan $staxDirL '0003-charlie.md' 'superseded' 'auth'
Push-Location $projL
try {
  Invoke-XX work-items list
  Assert-Eq 'exit 0' $RunRC 0
  $expected = @(
    "0003-charlie`tsuperseded`tauth"
    "0002-bravo`tdeprecated`tbilling"
    "0001-alpha`tvalid`tauth,billing"
  ) -join "`n"
  Assert-Eq 'desc order, tab-separated' $RunOut $expected
} finally { Pop-Location }

Start-Case 'work-items list --order=asc reverses to prefix-ascending'
Push-Location $projL
try {
  Invoke-XX work-items list --order=asc
  Assert-Eq 'exit 0' $RunRC 0
  $expected = @(
    "0001-alpha`tvalid`tauth,billing"
    "0002-bravo`tdeprecated`tbilling"
    "0003-charlie`tsuperseded`tauth"
  ) -join "`n"
  Assert-Eq 'asc order' $RunOut $expected
} finally { Pop-Location }

Start-Case 'work-items list --status filter keeps only matching rows'
Push-Location $projL
try {
  Invoke-XX work-items list --status valid
  Assert-Eq 'exit 0'           $RunRC 0
  Assert-Eq 'only valid rows' $RunOut "0001-alpha`tvalid`tauth,billing"
} finally { Pop-Location }

Start-Case 'work-items list --status accepts comma list'
Push-Location $projL
try {
  Invoke-XX work-items list --status 'valid,superseded'
  Assert-Eq 'exit 0' $RunRC 0
  $expected = @(
    "0003-charlie`tsuperseded`tauth"
    "0001-alpha`tvalid`tauth,billing"
  ) -join "`n"
  Assert-Eq 'comma-list filter (desc)' $RunOut $expected
} finally { Pop-Location }

Start-Case 'work-items list --system filter matches by kebab id'
Push-Location $projL
try {
  Invoke-XX work-items list --system billing
  Assert-Eq 'exit 0' $RunRC 0
  $expected = @(
    "0002-bravo`tdeprecated`tbilling"
    "0001-alpha`tvalid`tauth,billing"
  ) -join "`n"
  Assert-Eq 'system filter' $RunOut $expected
} finally { Pop-Location }

Start-Case 'work-items list combined --status and --system intersects both'
Push-Location $projL
try {
  Invoke-XX work-items list --status valid --system auth
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'status+system intersection' $RunOut "0001-alpha`tvalid`tauth,billing"
} finally { Pop-Location }

Start-Case 'work-items list --system <unknown id> returns zero rows'
Push-Location $projL
try {
  Invoke-XX work-items list --system never-declared
  Assert-Eq 'exit 0'    $RunRC 0
  Assert-Eq 'empty out' $RunOut ''
} finally { Pop-Location }

Start-Case 'work-items list rejects positional arguments'
Push-Location $projL
try {
  Invoke-XX work-items list foo
  Assert-Eq       'exit 2'     $RunRC 2
  Assert-Contains 'diagnostic' $RunErr 'takes no positional'
} finally { Pop-Location }

Start-Case 'work-items list warns on malformed frontmatter but keeps siblings'
$projWarn = New-FreshProject
Initialize-ProjectScaffold $projWarn
$staxDirW = Join-Path $projWarn $STAX_DIR
Write-Plan $staxDirW '0002-ok.md' 'valid' 'auth'
Set-Content -LiteralPath (Join-Path $staxDirW '0001-broken.md') -Value 'not a work item' -Encoding ascii
Push-Location $projWarn
try {
  Invoke-XX work-items list
  Assert-Eq       'exit 0'       $RunRC 0
  Assert-Eq       'kept the OK work item' $RunOut "0002-ok`tvalid`tauth"
  Assert-Contains 'warned about broken' $RunErr '0001-broken.md'
} finally { Pop-Location }

Start-Case 'work-items list ignores files that do not match the <prefix>-<slug>.md pattern'
$projP = New-FreshProject
Initialize-ProjectScaffold $projP
$staxDirP = Join-Path $projP $STAX_DIR
Write-Plan $staxDirP '0001-keep.md' 'valid' 'auth'
Set-Content -LiteralPath (Join-Path $staxDirP 'README.md')      -Value 'x' -Encoding ascii
Set-Content -LiteralPath (Join-Path $staxDirP '123-short.md')   -Value 'x' -Encoding ascii
Set-Content -LiteralPath (Join-Path $staxDirP '0002-noext')     -Value 'x' -Encoding ascii
Push-Location $projP
try {
  Invoke-XX work-items list
  Assert-Eq 'exit 0'         $RunRC 0
  Assert-Eq 'only keep'      $RunOut "0001-keep`tvalid`tauth"
} finally { Pop-Location }

# ---------- work-items lint (subset; full lint is exercised by the bash e2e) ----------

Start-Case 'work-items lint passes on a happy-path work item'
$projLN = New-FreshProject
Initialize-ProjectScaffold $projLN
$staxDirLN = Join-Path $projLN $STAX_DIR
Write-Registry $staxDirLN 'Auth Service'
$plan1 = Join-Path $staxDirLN '0001-foo.md'
$body1 = @"
---
title: foo
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath $plan1 -Value $body1 -Encoding ascii
Push-Location $projLN
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 0' $RunRC 0
  Assert-Contains 'ok line' $RunOut '0001-foo.md: ok'
} finally { Pop-Location }

Start-Case 'work-items lint flags filename slug mismatch with title'
$projLN2 = New-FreshProject
Initialize-ProjectScaffold $projLN2
$staxDirLN2 = Join-Path $projLN2 $STAX_DIR
Write-Registry $staxDirLN2 'Auth Service'
$plan2 = Join-Path $staxDirLN2 '0001-foo.md'
$body2 = @"
---
title: Totally Different
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath $plan2 -Value $body2 -Encoding ascii
Push-Location $projLN2
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'           $RunRC 1
  Assert-Contains 'filename↔title finding' $RunOut 'does not match slugify(title)'
} finally { Pop-Location }

Start-Case 'work-items lint flags an unknown declared system'
$projLN3 = New-FreshProject
Initialize-ProjectScaffold $projLN3
$staxDirLN3 = Join-Path $projLN3 $STAX_DIR
Write-Registry $staxDirLN3 'Auth Service'
$plan3 = Join-Path $staxDirLN3 '0001-foo.md'
$body3 = @"
---
title: foo
status: valid
systems: [ghost-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Ghost Service shall haunt.
"@
Set-Content -LiteralPath $plan3 -Value $body3 -Encoding ascii
Push-Location $projLN3
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'    $RunRC 1
  Assert-Contains 'finding'   $RunOut 'declared system "ghost-service" is not in'
} finally { Pop-Location }

Start-Case 'work-items lint flags a dangling supersedes link'
$projLN4 = New-FreshProject
Initialize-ProjectScaffold $projLN4
$staxDirLN4 = Join-Path $projLN4 $STAX_DIR
Write-Registry $staxDirLN4 'Auth Service'
$plan4 = Join-Path $staxDirLN4 '0001-foo.md'
$body4 = @"
---
title: foo
status: valid
systems: [auth-service]
supersedes: [00099-nope]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath $plan4 -Value $body4 -Encoding ascii
Push-Location $projLN4
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'  $RunRC 1
  Assert-Contains 'finding' $RunOut 'supersedes "00099-nope"'
} finally { Pop-Location }

# ---------- init (flag-driven, non-interactive) ----------

Start-Case 'init --scope project --agents claude end-to-end'
Reset-UserHome
$projInit = New-FreshProject
Push-Location $projInit
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq       'exit 0'             $RunRC 0
  Assert-IsDir    '.claude/skills present' (Join-Path $projInit $CLAUDE_SKILLS_REL)
  Assert-IsDir    'bundled stax skill landed' (Join-Path $projInit (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-IsDir    '.stax present' (Join-Path $projInit $STAX_DIR)
  Assert-IsFile   '_config.lock written' (Join-Path $projInit $Script:STAX_LOCK_PATH)
  Assert-IsFile   '_data_systems.yaml written' (Join-Path $projInit $Script:STAX_SYSTEMS_PATH)
  Assert-Contains 'git-commit tip' $RunOut "commit $STAX_DIR"
  # Lock file pins
  $lockContent = Get-Content -Raw -LiteralPath (Join-Path $projInit $Script:STAX_LOCK_PATH)
  Assert-Contains 'lock honors --prefix-width=4'   $lockContent '"prefix_width": 4'
  Assert-Contains 'lock honors --max-work-item-lines=30' $lockContent '"max_work_item_lines": 30'
  Assert-Contains 'lock honors --review-per=task'   $lockContent '"review_per": "task"'
} finally { Pop-Location }

Start-Case 'init --agents claude,codex installs both skill trees'
Reset-UserHome
$projInitBoth = New-FreshProject
Push-Location $projInitBoth
try {
  Invoke-XX init --scope project --agents 'claude,codex' `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'claude skills tree' (Join-Path $projInitBoth (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-IsDir 'codex skills tree'  (Join-Path $projInitBoth (Join-Path $CODEX_SKILLS_REL  $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents claude,codex,opencode installs all three skill trees'
Reset-UserHome
$projInitAll = New-FreshProject
Push-Location $projInitAll
try {
  Invoke-XX init --scope project --agents 'claude,codex,opencode' `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'claude skills tree'   (Join-Path $projInitAll (Join-Path $CLAUDE_SKILLS_REL   $SKILL_SHIP_DIR))
  Assert-IsDir 'codex skills tree'    (Join-Path $projInitAll (Join-Path $CODEX_SKILLS_REL    $SKILL_SHIP_DIR))
  Assert-IsDir 'opencode skills tree' (Join-Path $projInitAll (Join-Path $OPENCODE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init refuses re-run on an already-initialized project'
Reset-UserHome
$projInitRe = New-FreshProject
Push-Location $projInitRe
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'first init exit 0' $RunRC 0
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq       'second init exit 2' $RunRC 2
  Assert-Contains 'already-init banner' $RunErr 'already initialized'
} finally { Pop-Location }

Start-Case 'init --prefix-width=-1 is rejected'
Reset-UserHome
$projBad = New-FreshProject
Push-Location $projBad
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width=-1 --max-work-item-lines 30 --review-per task
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr '--prefix-width must be positive'
} finally { Pop-Location }

Start-Case 'init --max-work-item-lines=0 is rejected'
Reset-UserHome
$projBad2 = New-FreshProject
Push-Location $projBad2
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 0 --review-per task
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr '--max-work-item-lines must be positive'
} finally { Pop-Location }

Start-Case 'init --review-per=commit is rejected'
Reset-UserHome
$projBad3 = New-FreshProject
Push-Location $projBad3
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per commit
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr 'invalid --review-per'
} finally { Pop-Location }

Start-Case 'init --scope workspace is rejected'
Reset-UserHome
$projBad4 = New-FreshProject
Push-Location $projBad4
try {
  Invoke-XX init --scope workspace --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr 'invalid --scope'
} finally { Pop-Location }

Start-Case 'init --agents=workspace is rejected (unknown agent key)'
Reset-UserHome
$projBad5 = New-FreshProject
Push-Location $projBad5
try {
  Invoke-XX init --scope project --agents workspace `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr 'unknown agent'
} finally { Pop-Location }

# ---------- init (interactive, fed via stdin) ----------

Start-Case 'init interactive: prompts for agents/scope/prefix-width/max-work-item-lines/review-per'
Reset-UserHome
$projInt = New-FreshProject
Push-Location $projInt
try {
  # Order: agents (blank = all defaults to all), scope (1=project),
  # prefix-width (blank = default), max-work-item-lines (blank = default),
  # review-per (1=task).
  $Script:NextStdin = "`n1`n`n`n1`n"
  Invoke-XX init
  Assert-Eq    'exit 0'                 $RunRC 0
  Assert-IsDir '.claude/skills present' (Join-Path $projInt $CLAUDE_SKILLS_REL)
  Assert-IsDir '.stax present'       (Join-Path $projInit $STAX_DIR)
  $lockContentI = Get-Content -Raw -LiteralPath (Join-Path $projInt $Script:STAX_LOCK_PATH)
  Assert-Contains 'default prefix_width in lock' $lockContentI "`"prefix_width`": $DEFAULT_PREFIX_WIDTH"
  Assert-Contains 'default review_per in lock'   $lockContentI '"review_per": "task"'
} finally { Pop-Location }

# ---------- skills remove (end-to-end against a real init) ----------

Start-Case 'skills remove --project removes the project-scope install'
Reset-UserHome
$projSR = New-FreshProject
Push-Location $projSR
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'init exit 0' $RunRC 0
  Assert-IsDir 'skill present pre-remove' (Join-Path $projSR (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Invoke-XX skills remove --project
  Assert-Eq       'remove exit 0'       $RunRC 0
  Assert-Contains 'summary line'        $RunOut 'Removed'
  Assert-NotExists 'stax skill removed'  (Join-Path $projSR (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'skills remove --user is silent no-op on empty state'
Reset-UserHome
Push-Location (New-FreshProject)
try {
  Invoke-XX skills remove --user
  Assert-Eq       'exit 0'       $RunRC 0
  Assert-Contains 'summary line' $RunOut 'Removed 0'
} finally { Pop-Location }

Start-Case 'skills remove --project leaves user-authored sibling skills alone'
Reset-UserHome
$projOW = New-FreshProject
Push-Location $projOW
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  # Seed a sibling user-authored skill that stax must NOT touch.
  $siblingDir = Join-Path $projOW (Join-Path $CLAUDE_SKILLS_REL 'user-authored')
  New-Item -ItemType Directory -Force -Path $siblingDir | Out-Null
  Set-Content -LiteralPath (Join-Path $siblingDir 'SKILL.md') -Value '# user skill' -Encoding ascii
  Invoke-XX skills remove --project
  Assert-Eq        'remove exit 0'              $RunRC 0
  Assert-NotExists 'stax skill removed'          (Join-Path $projOW (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-IsDir     'sibling skill survived'     $siblingDir
  Assert-IsFile    'sibling SKILL.md survived'  (Join-Path $siblingDir 'SKILL.md')
} finally { Pop-Location }

# ==========================================================================
# Windows-specific cases
# ==========================================================================

# ---------- copy vs symlink ----------

Start-Case 'user-scope install uses COPY (not symlink) on Windows + seeds .stax in cwd'
Reset-UserHome
# Push to a throwaway dir so the cwd-scaffold assertion has a known scope.
$userInitCwd = New-FreshProject
Push-Location $userInitCwd
try {
  Invoke-XX init --scope user --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  $userClaudeSkill = Join-Path $env:USERPROFILE (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR)
  Assert-IsCopyNotSymlink 'stax skill is a copy, not symlink' $userClaudeSkill
  # User-scope MUST also drop the .stax/ scaffold into cwd. Scope only
  # decides where SKILLS land (project tree vs $env:USERPROFILE); the
  # project marker check keyed on <cwd>/$STAX_LOCK_PATH is what makes cwd usable
  # with /scope, /ship, and the `stax work-items *` CLI subcommands.
  Assert-IsFile 'user-scope seeds _config.lock in cwd' (Join-Path $userInitCwd $Script:STAX_LOCK_PATH)
  Assert-IsFile 'user-scope seeds _data_systems.yaml in cwd' (Join-Path $userInitCwd $Script:STAX_SYSTEMS_PATH)
} finally { Pop-Location }

Start-Case 'user-scope install copies bundled skill content verbatim'
$copySource = Join-Path $env:USERPROFILE (Join-Path $STAX_AGENTS_SKILLS_DIR (Join-Path $SKILL_SHIP_DIR $SKILL_MANIFEST_FILE))
$copyDest   = Join-Path $userClaudeSkill $SKILL_MANIFEST_FILE
Assert-IsFile 'source manifest exists' $copySource
Assert-IsFile 'dest manifest exists'   $copyDest
$srcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $copySource).Hash
$dstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $copyDest).Hash
Assert-Eq 'manifest content matches byte-for-byte' $srcHash $dstHash

# ---------- USERPROFILE scope resolution ----------

Start-Case 'user-scope install lands under %USERPROFILE%, not under $HOME if they differ'
Reset-UserHome
# `stax init` (any scope) seeds <cwd>/.stax/_config.lock, so each init
# call needs a fresh project dir — otherwise a leftover lock from an
# earlier case fails the "already initialized" check.
$projUP = New-FreshProject
Push-Location $projUP
try {
  # Diverge HOME and USERPROFILE so we can confirm Windows resolves to USERPROFILE.
  $divergedHome = Join-Path $Sandbox 'home-diverged'
  New-Item -ItemType Directory -Force -Path $divergedHome | Out-Null
  $env:HOME = $divergedHome
  $env:USERPROFILE = $SandboxHome
  Invoke-XX init --scope user --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'install under USERPROFILE' (Join-Path $env:USERPROFILE (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'NOT under HOME'        (Join-Path $env:HOME (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  # Restore HOME == USERPROFILE for subsequent cases that assume parity.
  $env:HOME = $SandboxHome
} finally { Pop-Location }

# ---------- CRLF tolerance ----------

Start-Case 'work-items list tolerates CRLF line endings in work-item files'
$projCR = New-FreshProject
Initialize-ProjectScaffold $projCR
$staxDirCR = Join-Path $projCR $STAX_DIR
$crlfPath = Join-Path $staxDirCR '0001-crlf.md'
# Write work item with explicit CRLF — mimics what Windows editors produce.
$crlfBody = "---`r`ntitle: crlf`r`nstatus: valid`r`nsystems: [auth]`r`ncreated: 2026-05-23T14:30:00Z`r`n---`r`n`r`n## Goal`r`ng`r`n`r`n## Approach`r`n- A`r`n`r`n## Tasks`r`n- [ ] The Auth Service shall do.`r`n"
[System.IO.File]::WriteAllText($crlfPath, $crlfBody)
Push-Location $projCR
try {
  Invoke-XX work-items list
  Assert-Eq 'exit 0'         $RunRC 0
  Assert-Eq 'crlf row parsed' $RunOut "0001-crlf`tvalid`tauth"
} finally { Pop-Location }

# ---------- reserved Windows filenames ----------
#
# Windows reserves CON, PRN, AUX, NUL, COM1-9, LPT1-9 as basenames. Older
# builds + Win32 APIs refuse creation outright; modern Windows (>=10 1903)
# accepts the create via .NET / NT-path APIs that bypass the Win32 reserved-
# name filter. The CLI never produces such names because every work item slug is
# prefixed with `\d{N}-` (so the basename is `<prefix>-<slug>`, never `CON`),
# and listPlans / scanHighestPrefix both anchor on that format via regex.
# This test verifies that anchor: if reserved-name files land in .stax/
# (whatever way), `work-items list` ignores them and `work-items next-prefix` keeps
# walking the conforming siblings.

Start-Case 'work-items list ignores reserved-name files at the .stax/ root'
$projRes = New-FreshProject
Initialize-ProjectScaffold $projRes
$staxDirRes = Join-Path $projRes $STAX_DIR
Write-Plan $staxDirRes '0001-foo.md' 'valid' 'auth'
# .NET I/O uses \\?\ NT-path prefixing on modern Windows, which bypasses
# the Win32 reserved-basename block. Track which reserved files we managed
# to create so the assertion below can't be silently vacuous on a host
# where every create fails.
$createdReserved = New-Object System.Collections.Generic.List[string]
foreach ($reserved in @('CON.md', 'PRN.md', 'AUX.md', 'NUL.md', 'COM1.md', 'LPT1.md')) {
  $target = Join-Path $staxDirRes $reserved
  try {
    [System.IO.File]::WriteAllText($target, 'x')
    if (Test-Path -LiteralPath $target -PathType Leaf) {
      [void]$createdReserved.Add($reserved)
    }
  } catch {}
}
if ($createdReserved.Count -eq 0) {
  Write-Fail 'no reserved-name files could be created on this host; CLI-tolerance assertion would be vacuous (investigate runner FS / pwsh version)'
} else {
  Push-Location $projRes
  try {
    Invoke-XX work-items list
    Assert-Eq 'exit 0' $RunRC 0
    Assert-Eq 'only conforming work item listed' $RunOut "0001-foo`tvalid`tauth"
    Invoke-XX work-items next-prefix
    Assert-Eq 'next-prefix unaffected by reserved-name files' $RunOut '0002'
  } finally { Pop-Location }
}

# ---------- case-insensitive filesystem ----------

Start-Case 'work-items list treats filenames case-insensitively (Windows NTFS default)'
$projCI = New-FreshProject
Initialize-ProjectScaffold $projCI
$staxDirCI = Join-Path $projCI $STAX_DIR
Write-Plan $staxDirCI '0001-foo.md' 'valid' 'auth'
# Trying to write a sibling differing only in case should hit the same file
# on NTFS. Just assert the original is reachable both ways.
Push-Location $projCI
try {
  Invoke-XX work-items list
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'lowercase reads OK' $RunOut "0001-foo`tvalid`tauth"
  # Same `work-items list`, lookup-by-uppercase shouldn't duplicate the row.
  Invoke-XX work-items list --system AUTH
  Assert-Eq 'uppercase --system does NOT case-fold to match' $RunOut ''
} finally { Pop-Location }

# ---------- spaces in install path ----------

Start-Case 'init survives a project path containing spaces and parens'
Reset-UserHome
$spacedDir = Join-Path $ProjectsRoot 'proj with (spaces)'
New-Item -ItemType Directory -Force -Path $spacedDir | Out-Null
Push-Location $spacedDir
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'skills present at spaced path' (Join-Path $spacedDir (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-IsFile 'lock present at spaced path'  (Join-Path $spacedDir $Script:STAX_LOCK_PATH)
} finally { Pop-Location }

# ---------- BOM tolerance in _config.lock ----------

Start-Case 'work-items next-prefix tolerates a UTF-8 BOM in _config.lock'
$projBOM = New-FreshProject
Initialize-ProjectScaffold $projBOM
$lockBOM = Join-Path (Join-Path $projBOM $STAX_DIR) $STAX_LOCK_FILE
$bomBytes = [System.Text.Encoding]::UTF8.GetPreamble() +
            [System.Text.Encoding]::UTF8.GetBytes('{"prefix_width":5,"max_work_item_lines":30,"review_per":"task"}')
[System.IO.File]::WriteAllBytes($lockBOM, $bomBytes)
Push-Location $projBOM
try {
  Invoke-XX work-items next-prefix
  # Go's encoding/json rejects a leading BOM, so the lock parse fails and we
  # fall back to defaultPrefixWidth (4). Document the fallback so a future
  # decision to BOM-strip explicitly is intentional.
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'falls back to defaultPrefixWidth on BOM' $RunOut '0001'
} finally { Pop-Location }

# ---------- forward-slash vs backslash CLI args ----------

Start-Case 'init accepts forward-slash paths in cwd (pwsh normalizes)'
Reset-UserHome
$fwdDir = Join-Path $ProjectsRoot 'fwdslash'
New-Item -ItemType Directory -Force -Path $fwdDir | Out-Null
Push-Location ($fwdDir -replace '\\', '/')
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'skills present under fwdslash cwd' (Join-Path $fwdDir (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

# ---------- work-items list: --overflow-keywords + threshold behavior ----------
#
# The overflow-keywords flag is contract-laden:
#   - No-op below threshold (always returns all rows)
#   - Engages above threshold (matched rows OR top-N fallback)
#   - Body-only match (frontmatter scalars don't count)
#   - Case-insensitive literal substring; multiple keywords = OR

# Helper: seed N body-only work items whose body is exactly the supplied content.
function Write-WorkItemWithBody {
  param(
    [Parameter(Mandatory)][string]$StaxDir,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Body
  )
  $fm = @"
---
status: valid
systems: [auth]
---
$Body
"@
  Set-Content -LiteralPath (Join-Path $StaxDir $Name) -Value $fm -Encoding ascii
}

function Add-ManyWorkItems {
  param(
    [Parameter(Mandatory)][string]$StaxDir,
    [Parameter(Mandatory)][int]$Count,
    [string]$Body = 'generic body'
  )
  for ($i = 1; $i -le $Count; $i++) {
    $name = '{0:D4}-work-item{1:D3}.md' -f $i, $i
    Write-WorkItemWithBody -StaxDir $StaxDir -Name $name -Body "$i $Body"
  }
}

Start-Case 'work-items list --overflow-keywords is a no-op below threshold'
$projOK1 = New-FreshProject
Initialize-ProjectScaffold $projOK1
$staxDirOK1 = Join-Path $projOK1 $STAX_DIR
Add-ManyWorkItems -StaxDir $staxDirOK1 -Count 5 -Body 'no match here'
Push-Location $projOK1
try {
  Invoke-XX work-items list --overflow-keywords zzz-never-matches
  Assert-Eq 'exit 0' $RunRC 0
  $rowCount = ($RunOut -split "`n").Count
  Assert-Eq 'all 5 rows returned (no-op below threshold)' $rowCount 5
} finally { Pop-Location }

Start-Case 'work-items list --overflow-keywords engages above threshold, matches body'
$projOK2 = New-FreshProject
Initialize-ProjectScaffold $projOK2
$staxDirOK2 = Join-Path $projOK2 $STAX_DIR
$over = $WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 5
Add-ManyWorkItems -StaxDir $staxDirOK2 -Count $over -Body 'generic body'
# Replace one body with a keyword the harness will look for.
Write-WorkItemWithBody -StaxDir $staxDirOK2 -Name '0007-work-item007.md' -Body 'this work item covers exponential retry backoff'
Push-Location $projOK2
try {
  Invoke-XX work-items list --overflow-keywords retry
  Assert-Eq       'exit 0'          $RunRC 0
  Assert-Contains 'matched work item in output' $RunOut 'work-item007'
  $rowCount = ($RunOut -split "`n").Count
  Assert-Eq 'exactly the matched row' $rowCount 1
} finally { Pop-Location }

Start-Case 'work-items list --overflow-keywords falls back to top-N when no body matches'
$projOK3 = New-FreshProject
Initialize-ProjectScaffold $projOK3
$staxDirOK3 = Join-Path $projOK3 $STAX_DIR
Add-ManyWorkItems -StaxDir $staxDirOK3 -Count ($WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 3) -Body 'nothing relevant here'
Push-Location $projOK3
try {
  Invoke-XX work-items list --overflow-keywords zzz-never-matches
  Assert-Eq 'exit 0' $RunRC 0
  $rowCount = ($RunOut -split "`n").Count
  Assert-Eq 'falls back to threshold rows' $rowCount $WORK_ITEMS_LIST_OVERFLOW_THRESHOLD
} finally { Pop-Location }

Start-Case 'work-items list --overflow-keywords matches body-only (frontmatter ignored)'
$projOK4 = New-FreshProject
Initialize-ProjectScaffold $projOK4
$staxDirOK4 = Join-Path $projOK4 $STAX_DIR
Add-ManyWorkItems -StaxDir $staxDirOK4 -Count ($WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 1) -Body 'generic body'
Push-Location $projOK4
try {
  # 'auth' appears in every work item's frontmatter (systems: [auth]) but NEVER in body.
  Invoke-XX work-items list --overflow-keywords auth
  Assert-Eq 'exit 0' $RunRC 0
  $rowCount = ($RunOut -split "`n").Count
  Assert-Eq 'frontmatter-only keyword triggers top-N fallback' $rowCount $WORK_ITEMS_LIST_OVERFLOW_THRESHOLD
} finally { Pop-Location }

Start-Case 'work-items list --overflow-keywords is case-insensitive'
$projOK5 = New-FreshProject
Initialize-ProjectScaffold $projOK5
$staxDirOK5 = Join-Path $projOK5 $STAX_DIR
Add-ManyWorkItems -StaxDir $staxDirOK5 -Count $WORK_ITEMS_LIST_OVERFLOW_THRESHOLD -Body 'generic body'
Write-WorkItemWithBody -StaxDir $staxDirOK5 -Name "$('{0:D4}' -f ($WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 1))-extra.md" -Body 'Uppercase MATCH inside body'
Push-Location $projOK5
try {
  Invoke-XX work-items list --overflow-keywords match
  Assert-Eq       'exit 0' $RunRC 0
  Assert-Contains 'lowercase keyword matches uppercase body' $RunOut 'extra'
} finally { Pop-Location }

Start-Case 'work-items list --overflow-keywords accepts multiple terms (OR semantics)'
$projOK6 = New-FreshProject
Initialize-ProjectScaffold $projOK6
$staxDirOK6 = Join-Path $projOK6 $STAX_DIR
Add-ManyWorkItems -StaxDir $staxDirOK6 -Count $WORK_ITEMS_LIST_OVERFLOW_THRESHOLD -Body 'generic body'
Write-WorkItemWithBody -StaxDir $staxDirOK6 -Name "$('{0:D4}' -f ($WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 1))-alpha.md" -Body 'mentions webhook only'
Write-WorkItemWithBody -StaxDir $staxDirOK6 -Name "$('{0:D4}' -f ($WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 2))-bravo.md" -Body 'mentions retry only'
Push-Location $projOK6
try {
  Invoke-XX work-items list --overflow-keywords 'webhook,retry'
  Assert-Eq       'exit 0' $RunRC 0
  Assert-Contains 'OR match: alpha present' $RunOut 'alpha'
  Assert-Contains 'OR match: bravo present' $RunOut 'bravo'
} finally { Pop-Location }

Start-Case 'work-items list --overflow-keywords repeated flag = comma list'
Push-Location $projOK6
try {
  Invoke-XX work-items list --overflow-keywords webhook --overflow-keywords retry
  Assert-Eq       'exit 0' $RunRC 0
  Assert-Contains 'repeated-flag alpha' $RunOut 'alpha'
  Assert-Contains 'repeated-flag bravo' $RunOut 'bravo'
} finally { Pop-Location }

Start-Case 'work-items list combined --system + --overflow-keywords narrows correctly'
$projOK7 = New-FreshProject
Initialize-ProjectScaffold $projOK7
$staxDirOK7 = Join-Path $projOK7 $STAX_DIR
$over7 = $WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 5
for ($i = 1; $i -le $over7; $i++) {
  $name7 = '{0:D4}-payment{0:D3}.md' -f $i
  $body7 = "---`nstatus: valid`nsystems: [payment-service]`n---`n$i generic body"
  Set-Content -LiteralPath (Join-Path $staxDirOK7 $name7) -Value $body7 -Encoding ascii
}
$plan7Match = '0007-payment007.md'
$plan7MatchBody = "---`nstatus: valid`nsystems: [payment-service]`n---`nthis work item covers exponential retry backoff"
Set-Content -LiteralPath (Join-Path $staxDirOK7 $plan7Match) -Value $plan7MatchBody -Encoding ascii
# An unrelated-system work item with the same body keyword — must be filtered out by --system.
$plan7Unrelated = '0099-unrelated.md'
$plan7UnrelatedBody = "---`nstatus: valid`nsystems: [other-system]`n---`nalso mentions retry"
Set-Content -LiteralPath (Join-Path $staxDirOK7 $plan7Unrelated) -Value $plan7UnrelatedBody -Encoding ascii
Push-Location $projOK7
try {
  Invoke-XX work-items list --system payment-service --overflow-keywords retry
  Assert-Eq           'exit 0' $RunRC 0
  Assert-Contains     'payment007 in match'             $RunOut 'payment007'
  Assert-NotContains  'unrelated filtered out before narrow' $RunOut 'unrelated'
  $rowCount = ($RunOut -split "`n").Count
  Assert-Eq 'exactly one match (id ∩ keyword)' $rowCount 1
} finally { Pop-Location }

Start-Case 'work-items list --status + --system + --overflow-keywords narrows status∩system > threshold'
# Proves --overflow-keywords is the layer that does the work when --status
# and --system are already applied. Pre-overflow count must exceed the
# threshold AFTER status+system filtering, and the distractors that share
# status AND system but lack the body keyword can ONLY be eliminated by
# the overflow narrow. Two further distractors carry the keyword in body
# but fail one of status / system — they assert layer ordering
# (status+system run BEFORE overflow, not after).
$projSSO = New-FreshProject
Initialize-ProjectScaffold $projSSO
$staxDirSSO = Join-Path $projSSO $STAX_DIR
# Threshold+2 work items, all status=valid + system=payment-service, body
# WITHOUT the keyword. Two of them (5, 17) get overwritten below with
# bodies that DO contain "retry".
$overSSO = $WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 2
for ($i = 1; $i -le $overSSO; $i++) {
  $nameSSO = '{0:D4}-work-item{1:D3}.md' -f $i, $i
  $bodySSO = "---`nstatus: valid`nsystems: [payment-service]`n---`n$i generic body content"
  Set-Content -LiteralPath (Join-Path $staxDirSSO $nameSSO) -Value $bodySSO -Encoding ascii
}
foreach ($matchN in 5, 17) {
  $matchName = '{0:D4}-work-item{1:D3}.md' -f $matchN, $matchN
  $matchBody = "---`nstatus: valid`nsystems: [payment-service]`n---`nwork item $matchN covers exponential retry backoff"
  Set-Content -LiteralPath (Join-Path $staxDirSSO $matchName) -Value $matchBody -Encoding ascii
}
# Cross-filter distractors: each carries "retry" in body but fails one
# of --status (deprecated) or --system (other-service). Must be dropped
# BEFORE the overflow narrow ever runs.
$ssoWrongStatusBody = "---`nstatus: deprecated`nsystems: [payment-service]`n---`ndeprecated work item that mentions retry"
Set-Content -LiteralPath (Join-Path $staxDirSSO '0098-wrong-status.md') -Value $ssoWrongStatusBody -Encoding ascii
$ssoWrongSystemBody = "---`nstatus: valid`nsystems: [other-service]`n---`nother-service work item that mentions retry"
Set-Content -LiteralPath (Join-Path $staxDirSSO '0099-wrong-system.md') -Value $ssoWrongSystemBody -Encoding ascii
Push-Location $projSSO
try {
  Invoke-XX work-items list --status valid --system payment-service --overflow-keywords retry
  Assert-Eq          'exit 0'                                    $RunRC 0
  Assert-Contains    'work-item005 in match'                          $RunOut 'work-item005'
  Assert-Contains    'work-item017 in match'                          $RunOut 'work-item017'
  Assert-NotContains 'wrong-status filtered by --status filter'     $RunOut 'wrong-status'
  Assert-NotContains 'wrong-system filtered by --system filter'     $RunOut 'wrong-system'
  $rowCountSSO = ($RunOut -split "`n").Count
  Assert-Eq 'exactly two matchers survive (status ∩ system ∩ keyword)' $rowCountSSO 2
} finally { Pop-Location }

Start-Case 'work-items list --order=desc explicit default'
$projOK8 = New-FreshProject
Initialize-ProjectScaffold $projOK8
$staxDirOK8 = Join-Path $projOK8 $STAX_DIR
Write-Plan $staxDirOK8 '0001-alpha.md' 'valid' 'auth'
Write-Plan $staxDirOK8 '0002-bravo.md' 'valid' 'auth'
Push-Location $projOK8
try {
  Invoke-XX work-items list --order=desc
  Assert-Eq 'exit 0' $RunRC 0
  $expected = @("0002-bravo`tvalid`tauth", "0001-alpha`tvalid`tauth") -join "`n"
  Assert-Eq 'explicit desc matches default' $RunOut $expected
} finally { Pop-Location }

Start-Case 'work-items list --order=bogus rejected'
Push-Location $projOK8
try {
  Invoke-XX work-items list --order=bogus
  Assert-Eq       'exit 2'     $RunRC 2
  Assert-Contains 'diagnostic' $RunErr '--order must be'
} finally { Pop-Location }

Start-Case 'work-items list --system <id1>,<id2> OR semantics via comma list'
$projOK9 = New-FreshProject
Initialize-ProjectScaffold $projOK9
$staxDirOK9 = Join-Path $projOK9 $STAX_DIR
Write-Plan $staxDirOK9 '0001-a.md' 'valid' 'checkout-service'
Write-Plan $staxDirOK9 '0002-b.md' 'valid' 'payment-audit-log'
Write-Plan $staxDirOK9 '0003-c.md' 'valid' 'other-system'
Push-Location $projOK9
try {
  Invoke-XX work-items list --system 'checkout-service,payment-audit-log' --order=asc
  Assert-Eq 'exit 0' $RunRC 0
  $expected = @("0001-a`tvalid`tcheckout-service", "0002-b`tvalid`tpayment-audit-log") -join "`n"
  Assert-Eq 'comma-list OR' $RunOut $expected
} finally { Pop-Location }

Start-Case 'work-items list --system repeated flag matches comma form'
Push-Location $projOK9
try {
  Invoke-XX work-items list --system checkout-service --system payment-audit-log --order=asc
  Assert-Eq 'exit 0' $RunRC 0
  $expected = @("0001-a`tvalid`tcheckout-service", "0002-b`tvalid`tpayment-audit-log") -join "`n"
  Assert-Eq 'repeated-flag OR' $RunOut $expected
} finally { Pop-Location }

Start-Case 'work-items list --system matches any element of a multi-id systems array'
$projOK10 = New-FreshProject
Initialize-ProjectScaffold $projOK10
$staxDirOK10 = Join-Path $projOK10 $STAX_DIR
Write-Plan $staxDirOK10 '0001-multi.md' 'valid' 'checkout-service,payment-audit-log'
Write-Plan $staxDirOK10 '0002-other.md' 'valid' 'other-system'
Push-Location $projOK10
try {
  Invoke-XX work-items list --system payment-audit-log
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'single-id flag matches multi-id row' $RunOut "0001-multi`tvalid`tcheckout-service,payment-audit-log"
} finally { Pop-Location }

# ---------- work-items lint: full per-check matrix ----------

# Writes a complete, lint-clean work item to .stax/name with the given status,
# inline systems id list, and EARS subject display name. Cases override one
# field to trip a single finding.
function Write-FullPlan {
  param(
    [Parameter(Mandatory)][string]$StaxDir,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][string]$SystemIds,
    [Parameter(Mandatory)][string]$EarsSubject
  )
  $slug = ($Name -replace '\.md$', '') -replace '^\d+-', ''
  $body = @"
---
title: $slug
status: $Status
systems: [$SystemIds]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The $EarsSubject shall do.
"@
  Set-Content -LiteralPath (Join-Path $StaxDir $Name) -Value $body -Encoding ascii
}

Start-Case 'work-items lint passes on a clean single-system work item'
$projLNa = New-FreshProject
Initialize-ProjectScaffold $projLNa
Write-Registry (Join-Path $projLNa $STAX_DIR) 'Auth Service'
Write-FullPlan (Join-Path $projLNa $STAX_DIR) '0001-foo.md' 'valid' 'auth-service' 'Auth Service'
Push-Location $projLNa
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 0'    $RunRC 0
  Assert-Contains 'ok line'   $RunOut '0001-foo.md: ok'
  Assert-Contains 'summary'   $RunErr '1 ok'
} finally { Pop-Location }

Start-Case 'work-items lint passes on a clean multi-system work item'
$projLNb = New-FreshProject
Initialize-ProjectScaffold $projLNb
Write-Registry (Join-Path $projLNb $STAX_DIR) 'Auth Service,Billing Service'
$staxDirLNb = Join-Path $projLNb $STAX_DIR
$body = @"
---
title: foo
status: valid
systems: [auth-service, billing-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall authenticate.
- [ ] The Billing Service shall invoice.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNb '0001-foo.md') -Value $body -Encoding ascii
Push-Location $projLNb
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 0'  $RunRC 0
  Assert-Contains 'ok line' $RunOut '0001-foo.md: ok'
} finally { Pop-Location }

Start-Case 'work-items lint flags a bad filename (non-conforming pattern)'
$projLNc = New-FreshProject
Initialize-ProjectScaffold $projLNc
Write-Registry (Join-Path $projLNc $STAX_DIR) 'Auth Service'
Write-FullPlan (Join-Path $projLNc $STAX_DIR) 'BAD-NAME.md' 'valid' 'auth-service' 'Auth Service'
Push-Location $projLNc
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                $RunRC 1
  Assert-Contains 'filename finding'      $RunOut 'does not match'
} finally { Pop-Location }

Start-Case 'work-items lint flags a missing _data_systems.yaml entry'
$projLNd = New-FreshProject
Initialize-ProjectScaffold $projLNd
# Registry has only Auth; work item references ghost.
Write-Registry (Join-Path $projLNd $STAX_DIR) 'Auth Service'
Write-FullPlan (Join-Path $projLNd $STAX_DIR) '0001-foo.md' 'valid' 'ghost-service' 'Ghost Service'
Push-Location $projLNd
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                  $RunRC 1
  Assert-Contains 'id-not-in-registry'      $RunOut 'declared system "ghost-service" is not in'
} finally { Pop-Location }

Start-Case 'work-items lint flags an invalid status'
$projLNe = New-FreshProject
Initialize-ProjectScaffold $projLNe
Write-Registry (Join-Path $projLNe $STAX_DIR) 'Auth Service'
Write-FullPlan (Join-Path $projLNe $STAX_DIR) '0001-foo.md' 'bogus' 'auth-service' 'Auth Service'
Push-Location $projLNe
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'           $RunRC 1
  Assert-Contains 'status finding'   $RunOut 'status "bogus" is not one of'
} finally { Pop-Location }

Start-Case 'work-items lint flags a missing title:'
$projLNf = New-FreshProject
Initialize-ProjectScaffold $projLNf
Write-Registry (Join-Path $projLNf $STAX_DIR) 'Auth Service'
$staxDirLNf = Join-Path $projLNf $STAX_DIR
$bodyMissingTitle = @"
---
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNf '0001-foo.md') -Value $bodyMissingTitle -Encoding ascii
Push-Location $projLNf
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'          $RunRC 1
  Assert-Contains 'title finding'   $RunOut 'missing required `title:`'
} finally { Pop-Location }

Start-Case 'work-items lint flags an empty title:'
$projLNg = New-FreshProject
Initialize-ProjectScaffold $projLNg
Write-Registry (Join-Path $projLNg $STAX_DIR) 'Auth Service'
$staxDirLNg = Join-Path $projLNg $STAX_DIR
$bodyEmptyTitle = @"
---
title: ""
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNg '0001-foo.md') -Value $bodyEmptyTitle -Encoding ascii
Push-Location $projLNg
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                  $RunRC 1
  Assert-Contains 'empty-title finding'     $RunOut '`title:` value is empty'
} finally { Pop-Location }

Start-Case 'work-items lint flags a missing created:'
$projLNh = New-FreshProject
Initialize-ProjectScaffold $projLNh
Write-Registry (Join-Path $projLNh $STAX_DIR) 'Auth Service'
$staxDirLNh = Join-Path $projLNh $STAX_DIR
$bodyMissingCreated = @"
---
title: foo
status: valid
systems: [auth-service]
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNh '0001-foo.md') -Value $bodyMissingCreated -Encoding ascii
Push-Location $projLNh
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'             $RunRC 1
  Assert-Contains 'created finding'    $RunOut 'missing required `created:`'
} finally { Pop-Location }

Start-Case 'work-items lint flags a malformed created: timestamp'
$projLNi = New-FreshProject
Initialize-ProjectScaffold $projLNi
Write-Registry (Join-Path $projLNi $STAX_DIR) 'Auth Service'
$staxDirLNi = Join-Path $projLNi $STAX_DIR
$bodyBadCreated = @"
---
title: foo
status: valid
systems: [auth-service]
created: yesterday
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNi '0001-foo.md') -Value $bodyBadCreated -Encoding ascii
Push-Location $projLNi
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                     $RunRC 1
  Assert-Contains 'malformed-created finding'  $RunOut '"yesterday" is not an ISO 8601'
} finally { Pop-Location }

Start-Case 'work-items lint flags date-only created: (no time component)'
$projLNj = New-FreshProject
Initialize-ProjectScaffold $projLNj
Write-Registry (Join-Path $projLNj $STAX_DIR) 'Auth Service'
$staxDirLNj = Join-Path $projLNj $STAX_DIR
$bodyDateOnly = @"
---
title: foo
status: valid
systems: [auth-service]
created: 2026-05-23
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNj '0001-foo.md') -Value $bodyDateOnly -Encoding ascii
Push-Location $projLNj
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                 $RunRC 1
  Assert-Contains 'date-only finding'      $RunOut '"2026-05-23" is not an ISO 8601'
} finally { Pop-Location }

Start-Case 'work-items lint flags title-not-first (frontmatter order)'
$projLNk = New-FreshProject
Initialize-ProjectScaffold $projLNk
Write-Registry (Join-Path $projLNk $STAX_DIR) 'Auth Service'
$staxDirLNk = Join-Path $projLNk $STAX_DIR
$bodyOrderTitle = @"
---
status: valid
title: foo
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNk '0001-foo.md') -Value $bodyOrderTitle -Encoding ascii
Push-Location $projLNk
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                  $RunRC 1
  Assert-Contains 'title-first finding'     $RunOut 'must be the first frontmatter field'
} finally { Pop-Location }

Start-Case 'work-items lint flags created-not-last (frontmatter order)'
$projLNm = New-FreshProject
Initialize-ProjectScaffold $projLNm
Write-Registry (Join-Path $projLNm $STAX_DIR) 'Auth Service'
$staxDirLNm = Join-Path $projLNm $STAX_DIR
$bodyOrderCreated = @"
---
title: foo
created: 2026-05-23T14:30:00Z
status: valid
systems: [auth-service]
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNm '0001-foo.md') -Value $bodyOrderCreated -Encoding ascii
Push-Location $projLNm
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                  $RunRC 1
  Assert-Contains 'created-last finding'    $RunOut 'must be the last frontmatter field'
} finally { Pop-Location }

Start-Case 'work-items lint flags dangling supersedes link'
$projLNn = New-FreshProject
Initialize-ProjectScaffold $projLNn
Write-Registry (Join-Path $projLNn $STAX_DIR) 'Auth Service'
$staxDirLNn = Join-Path $projLNn $STAX_DIR
$bodyDangling = @"
---
title: foo
status: valid
systems: [auth-service]
supersedes: [00099-nope]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNn '0001-foo.md') -Value $bodyDangling -Encoding ascii
Push-Location $projLNn
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                   $RunRC 1
  Assert-Contains 'dangling-supersedes'      $RunOut 'supersedes "00099-nope"'
} finally { Pop-Location }

Start-Case 'work-items lint flags dangling extends link'
$projLNo = New-FreshProject
Initialize-ProjectScaffold $projLNo
Write-Registry (Join-Path $projLNo $STAX_DIR) 'Auth Service'
$staxDirLNo = Join-Path $projLNo $STAX_DIR
$bodyDanglingExt = @"
---
title: foo
status: valid
systems: [auth-service]
extends: [00099-nope]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNo '0001-foo.md') -Value $bodyDanglingExt -Encoding ascii
Push-Location $projLNo
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                $RunRC 1
  Assert-Contains 'dangling-extends'      $RunOut 'extends "00099-nope"'
} finally { Pop-Location }

Start-Case 'work-items lint rejects self-supersedes'
$projLNp = New-FreshProject
Initialize-ProjectScaffold $projLNp
Write-Registry (Join-Path $projLNp $STAX_DIR) 'Auth Service'
$staxDirLNp = Join-Path $projLNp $STAX_DIR
$bodySelfSup = @"
---
title: foo
status: valid
systems: [auth-service]
supersedes: [0001-foo]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNp '0001-foo.md') -Value $bodySelfSup -Encoding ascii
Push-Location $projLNp
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                   $RunRC 1
  Assert-Contains 'self-supersedes finding'  $RunOut 'cannot reference the work item itself'
} finally { Pop-Location }

Start-Case 'work-items lint rejects self-extends'
$projLNq = New-FreshProject
Initialize-ProjectScaffold $projLNq
Write-Registry (Join-Path $projLNq $STAX_DIR) 'Auth Service'
$staxDirLNq = Join-Path $projLNq $STAX_DIR
$bodySelfExt = @"
---
title: foo
status: valid
systems: [auth-service]
extends: [0001-foo]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNq '0001-foo.md') -Value $bodySelfExt -Encoding ascii
Push-Location $projLNq
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                 $RunRC 1
  Assert-Contains 'self-extends finding'   $RunOut 'cannot reference the work item itself'
} finally { Pop-Location }

Start-Case 'work-items lint flags missing extends back-link (bidirectional)'
$projLNr = New-FreshProject
Initialize-ProjectScaffold $projLNr
Write-Registry (Join-Path $projLNr $STAX_DIR) 'Auth Service'
$staxDirLNr = Join-Path $projLNr $STAX_DIR
# Plan A extends B. B exists but has no extended_by back-link to A.
Write-FullPlan $staxDirLNr '0002-bar.md' 'valid' 'auth-service' 'Auth Service'
$bodyAExtB = @"
---
title: foo
status: valid
systems: [auth-service]
extends: [0002-bar]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNr '0001-foo.md') -Value $bodyAExtB -Encoding ascii
Push-Location $projLNr
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                       $RunRC 1
  Assert-Contains 'missing back-link finding'    $RunOut 'does not list this work item in its `extended_by:`'
} finally { Pop-Location }

Start-Case 'work-items lint flags missing supersedes back-link (bidirectional)'
$projLNs = New-FreshProject
Initialize-ProjectScaffold $projLNs
Write-Registry (Join-Path $projLNs $STAX_DIR) 'Auth Service'
$staxDirLNs = Join-Path $projLNs $STAX_DIR
Write-FullPlan $staxDirLNs '0002-bar.md' 'valid' 'auth-service' 'Auth Service'
$bodyASupB = @"
---
title: foo
status: valid
systems: [auth-service]
supersedes: [0002-bar]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNs '0001-foo.md') -Value $bodyASupB -Encoding ascii
Push-Location $projLNs
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                       $RunRC 1
  Assert-Contains 'missing back-link finding'    $RunOut 'does not list this work item in its `superseded_by:`'
} finally { Pop-Location }

Start-Case 'work-items lint passes bidirectional supersedes when both sides linked'
$projLNt = New-FreshProject
Initialize-ProjectScaffold $projLNt
Write-Registry (Join-Path $projLNt $STAX_DIR) 'Auth Service'
$staxDirLNt = Join-Path $projLNt $STAX_DIR
$bodySup = @"
---
title: foo
status: valid
systems: [auth-service]
supersedes: [0002-bar]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
$bodySupedBy = @"
---
title: bar
status: superseded
systems: [auth-service]
superseded_by: [0001-foo]
created: 2026-05-22T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNt '0001-foo.md') -Value $bodySup -Encoding ascii
Set-Content -LiteralPath (Join-Path $staxDirLNt '0002-bar.md') -Value $bodySupedBy -Encoding ascii
Push-Location $projLNt
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 0'    $RunRC 0
  Assert-Contains 'summary'   $RunErr '2 ok'
} finally { Pop-Location }

Start-Case 'work-items lint flags EARS subject not in registry'
$projLNu = New-FreshProject
Initialize-ProjectScaffold $projLNu
Write-Registry (Join-Path $projLNu $STAX_DIR) 'Auth Service'
$staxDirLNu = Join-Path $projLNu $STAX_DIR
# Frontmatter declares the id cleanly, but body subject is unregistered.
$bodyUnknownSubject = @"
---
title: foo
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Phantom Service shall haunt.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNu '0001-foo.md') -Value $bodyUnknownSubject -Encoding ascii
Push-Location $projLNu
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                  $RunRC 1
  Assert-Contains 'unknown-subject finding' $RunOut 'EARS subject "Phantom Service" is not in'
} finally { Pop-Location }

Start-Case 'work-items lint flags EARS-subject ↔ systems set divergence'
$projLNv = New-FreshProject
Initialize-ProjectScaffold $projLNv
Write-Registry (Join-Path $projLNv $STAX_DIR) 'Auth Service,Billing Service'
$staxDirLNv = Join-Path $projLNv $STAX_DIR
# systems declares Auth, body names Billing — both diff directions fire.
$bodyDiverge = @"
---
title: foo
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Billing Service shall invoice.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNv '0001-foo.md') -Value $bodyDiverge -Encoding ascii
Push-Location $projLNv
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                        $RunRC 1
  Assert-Contains 'subject-not-declared finding'  $RunOut 'EARS tasks name systems not in `systems:`'
  Assert-Contains 'declared-not-used finding'     $RunOut '`systems:` declares systems not used in any EARS task'
} finally { Pop-Location }

Start-Case 'work-items lint flags filename slug not matching slugify(title)'
$projLNw = New-FreshProject
Initialize-ProjectScaffold $projLNw
Write-Registry (Join-Path $projLNw $STAX_DIR) 'Auth Service'
$staxDirLNw = Join-Path $projLNw $STAX_DIR
# Title slugifies to "totally-different" but filename slug is "foo".
$bodyTitleMismatch = @"
---
title: Totally Different
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNw '0001-foo.md') -Value $bodyTitleMismatch -Encoding ascii
Push-Location $projLNw
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                        $RunRC 1
  Assert-Contains 'title↔filename finding'        $RunOut 'does not match slugify(title)'
} finally { Pop-Location }

Start-Case 'work-items lint flags missing required section ## Goal'
$projLNx = New-FreshProject
Initialize-ProjectScaffold $projLNx
Write-Registry (Join-Path $projLNx $STAX_DIR) 'Auth Service'
$staxDirLNx = Join-Path $projLNx $STAX_DIR
$bodyMissingGoal = @"
---
title: foo
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNx '0001-foo.md') -Value $bodyMissingGoal -Encoding ascii
Push-Location $projLNx
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'           $RunRC 1
  Assert-Contains 'goal finding'     $RunOut 'missing required section "## Goal"'
} finally { Pop-Location }

Start-Case 'work-items lint flags file exceeding max_work_item_lines'
$projLNy = New-FreshProject
Initialize-ProjectScaffold $projLNy
# Pin max_work_item_lines=15 so a 30-line file trips the cap.
$lockY = Join-Path (Join-Path $projLNy $STAX_DIR) $STAX_LOCK_FILE
Set-Content -LiteralPath $lockY -Value '{"prefix_width":4,"max_work_item_lines":15,"review_per":"task"}' -Encoding ascii
Write-Registry (Join-Path $projLNy $STAX_DIR) 'Auth Service'
$staxDirLNy = Join-Path $projLNy $STAX_DIR
$bodyLong = @"
---
title: foo
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A
- B
- C
- D

## Tasks
- [ ] The Auth Service shall a.
- [ ] The Auth Service shall b.
- [ ] The Auth Service shall c.
- [ ] The Auth Service shall d.
- [ ] The Auth Service shall e.
- [ ] The Auth Service shall f.
"@
Set-Content -LiteralPath (Join-Path $staxDirLNy '0001-foo.md') -Value $bodyLong -Encoding ascii
Push-Location $projLNy
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                $RunRC 1
  Assert-Contains 'line-cap finding'      $RunOut 'max is 15'
} finally { Pop-Location }

Start-Case 'work-items lint flags missing frontmatter entirely'
$projLNz = New-FreshProject
Initialize-ProjectScaffold $projLNz
Write-Registry (Join-Path $projLNz $STAX_DIR) 'Auth Service'
$staxDirLNz = Join-Path $projLNz $STAX_DIR
Set-Content -LiteralPath (Join-Path $staxDirLNz '0001-foo.md') -Value "no frontmatter here`n" -Encoding ascii
Push-Location $projLNz
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                  $RunRC 1
  Assert-Contains 'no-frontmatter finding'  $RunOut 'missing YAML frontmatter'
} finally { Pop-Location }

# ---------- init flag matrix ----------

Start-Case 'init -h prints init usage to stderr'
Invoke-XX init -h
Assert-Eq       'exit 0'                $RunRC 0
Assert-Contains 'usage header'          $RunErr 'Usage: stax init'
Assert-Contains 'agents flag listed'    $RunErr '--agents'
Assert-Contains 'scope flag listed'     $RunErr '--scope'
Assert-Contains 'prefix-width listed'   $RunErr '--prefix-width'
Assert-Contains 'max-work-item-lines listed' $RunErr '--max-work-item-lines'
Assert-Contains 'review-per listed'     $RunErr '--review-per'

Start-Case 'init --agents=claude single-agent install'
Reset-UserHome
$projF1 = New-FreshProject
Push-Location $projF1
try {
  Invoke-XX init --scope project --agents=claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq        'exit 0'                  $RunRC 0
  Assert-IsDir     'claude skills present'   (Join-Path $projF1 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'codex skills NOT present' (Join-Path $projF1 (Join-Path $CODEX_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=codex single-agent install'
Reset-UserHome
$projF2 = New-FreshProject
Push-Location $projF2
try {
  Invoke-XX init --scope project --agents=codex `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq        'exit 0'                   $RunRC 0
  Assert-IsDir     'codex skills present'    (Join-Path $projF2 (Join-Path $CODEX_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'claude skills NOT present' (Join-Path $projF2 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=opencode single-agent install'
Reset-UserHome
$projF2o = New-FreshProject
Push-Location $projF2o
try {
  Invoke-XX init --scope project --agents=opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq        'exit 0'                     $RunRC 0
  Assert-IsDir     'opencode skills present'    (Join-Path $projF2o (Join-Path $OPENCODE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'claude skills NOT present'  (Join-Path $projF2o (Join-Path $CLAUDE_SKILLS_REL   $SKILL_SHIP_DIR))
  Assert-NotExists 'codex skills NOT present'   (Join-Path $projF2o (Join-Path $CODEX_SKILLS_REL    $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=copilot project-scope install'
Reset-UserHome
$projCP1 = New-FreshProject
Push-Location $projCP1
try {
  Invoke-XX init --scope project --agents=copilot `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  # Project scope: same `.agents/skills` path Codex uses.
  Assert-IsDir 'copilot project skills present' `
    (Join-Path $projCP1 (Join-Path $COPILOT_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'claude skills NOT present' `
    (Join-Path $projCP1 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=copilot --scope=user lands at ~/.agents/skills'
Reset-UserHome
$projCP2 = New-FreshProject
Push-Location $projCP2
try {
  Invoke-XX init --scope user --agents=copilot `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  # User scope: copilot reuses Codex's `.agents/skills` (cross-agent open
  # spec, one of two official Copilot CLI user-scope paths). Skills land
  # under USERPROFILE, project cwd untouched.
  Assert-IsDir 'copilot user-scope skills landed' `
    (Join-Path $env:USERPROFILE (Join-Path $COPILOT_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'no install under project cwd' `
    (Join-Path $projCP2 (Join-Path $COPILOT_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=pi project-scope install'
Reset-UserHome
$projPi1 = New-FreshProject
Push-Location $projPi1
try {
  Invoke-XX init --scope project --agents=pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  # Project scope: same `.agents\skills` path Codex and Copilot use,
  # documented for pi in pi-mono/packages/coding-agent/docs/skills.md
  # (walks up from cwd through ancestor directories).
  Assert-IsDir 'pi project skills present' `
    (Join-Path $projPi1 (Join-Path $PI_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'claude skills NOT present' `
    (Join-Path $projPi1 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=pi --scope=user lands at ~/.agents/skills'
Reset-UserHome
$projPi2 = New-FreshProject
Push-Location $projPi2
try {
  Invoke-XX init --scope user --agents=pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  # User scope: pi reads `~/.agents/skills/` (one of two documented
  # global locations per pi-mono/packages/coding-agent/docs/skills.md,
  # alongside `~/.pi/agent/skills/`). Skills land under USERPROFILE,
  # project cwd untouched.
  Assert-IsDir 'pi user-scope skills landed' `
    (Join-Path $env:USERPROFILE (Join-Path $PI_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'no install under project cwd' `
    (Join-Path $projPi2 (Join-Path $PI_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=cursor project-scope install (shared .agents\skills)'
Reset-UserHome
$projCur1 = New-FreshProject
Push-Location $projCur1
try {
  Invoke-XX init --scope project --agents=cursor `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'cursor project skills present' `
    (Join-Path $projCur1 (Join-Path $CURSOR_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'claude path NOT present' `
    (Join-Path $projCur1 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=cursor --scope=user lands at ~\.cursor\skills'
Reset-UserHome
$projCur2 = New-FreshProject
Push-Location $projCur2
try {
  Invoke-XX init --scope user --agents=cursor `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  # Cursor diverges at user scope (userSkillsRel override). Skills
  # land at `~\.cursor\skills`; the cross-agent `~\.agents\skills`
  # must stay clean to prove the override drove the install.
  Assert-IsDir 'cursor user-scope skills landed' `
    (Join-Path $env:USERPROFILE (Join-Path $CURSOR_USER_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'cross-agent ~\.agents\skills NOT touched' `
    (Join-Path $env:USERPROFILE (Join-Path $CODEX_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'no install under project cwd' `
    (Join-Path $projCur2 (Join-Path $CURSOR_USER_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=kilo project-scope install (.kilocode\skills)'
Reset-UserHome
$projKilo1 = New-FreshProject
Push-Location $projKilo1
try {
  Invoke-XX init --scope project --agents=kilo `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'kilo project skills present' `
    (Join-Path $projKilo1 (Join-Path $KILO_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'claude path NOT present' `
    (Join-Path $projKilo1 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'codex path NOT present' `
    (Join-Path $projKilo1 (Join-Path $CODEX_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=kilo --scope=user lands at ~\.kilocode\skills'
Reset-UserHome
$projKilo2 = New-FreshProject
Push-Location $projKilo2
try {
  Invoke-XX init --scope user --agents=kilo `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'kilo user-scope skills landed' `
    (Join-Path $env:USERPROFILE (Join-Path $KILO_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'no install under project cwd' `
    (Join-Path $projKilo2 (Join-Path $KILO_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=zed project-scope install (shared .agents\skills)'
Reset-UserHome
$projZed1 = New-FreshProject
Push-Location $projZed1
try {
  Invoke-XX init --scope project --agents=zed `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsDir 'zed project skills present' `
    (Join-Path $projZed1 (Join-Path $ZED_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'claude path NOT present' `
    (Join-Path $projZed1 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --agents=zed --scope=user lands at ~\.agents\skills'
Reset-UserHome
$projZed2 = New-FreshProject
Push-Location $projZed2
try {
  Invoke-XX init --scope user --agents=zed `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  # Zed honors the cross-agent path at BOTH scopes — same as omp/
  # Codex/Copilot/Pi at user scope.
  Assert-IsDir 'zed user-scope skills landed' `
    (Join-Path $env:USERPROFILE (Join-Path $ZED_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'no install under project cwd' `
    (Join-Path $projZed2 (Join-Path $ZED_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'init --prefix-width=6 seeds the lock with 6'
Reset-UserHome
$projF3 = New-FreshProject
Push-Location $projF3
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 6 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  $lockContent = Get-Content -Raw -LiteralPath (Join-Path $projF3 $Script:STAX_LOCK_PATH)
  Assert-Contains 'lock has prefix_width=6'   $lockContent '"prefix_width": 6'
  Invoke-XX work-items next-prefix
  Assert-Eq '6-wide prefix on next-prefix' $RunOut '000001'
} finally { Pop-Location }

Start-Case 'init --max-work-item-lines=50 seeds the lock with 50'
Reset-UserHome
$projF4 = New-FreshProject
Push-Location $projF4
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 50 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  $lockContent = Get-Content -Raw -LiteralPath (Join-Path $projF4 $Script:STAX_LOCK_PATH)
  Assert-Contains 'lock has max_work_item_lines=50' $lockContent '"max_work_item_lines": 50'
} finally { Pop-Location }

Start-Case 'init --review-per=work-item seeds the lock with work-item'
Reset-UserHome
$projF5 = New-FreshProject
Push-Location $projF5
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per work-item
  Assert-Eq 'exit 0' $RunRC 0
  $lockContent = Get-Content -Raw -LiteralPath (Join-Path $projF5 $Script:STAX_LOCK_PATH)
  Assert-Contains 'lock has review_per=work-item' $lockContent '"review_per": "work-item"'
} finally { Pop-Location }

Start-Case 'init --scope=user installs to user home, not project cwd'
Reset-UserHome
$projF6 = New-FreshProject
Push-Location $projF6
try {
  Invoke-XX init --scope user --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq        'exit 0'                       $RunRC 0
  Assert-IsDir     'install under USERPROFILE'    (Join-Path $env:USERPROFILE (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'no install under project cwd' (Join-Path $projF6 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  # $HOME/.stax/ itself exists under user scope — it holds the materialized
  # embed (binary-owned). The project marker (_config.lock) must NOT leak
  # there; it lives in cwd's .stax/ only.
  Assert-NotExists 'no project marker under user home' (Join-Path $env:USERPROFILE (Join-Path $STAX_DIR $STAX_LOCK_FILE))
} finally { Pop-Location }

Start-Case 'init --agents= (empty value) is rejected'
Reset-UserHome
$projF7 = New-FreshProject
Push-Location $projF7
try {
  Invoke-XX init --scope project --agents= `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr '--agents'
} finally { Pop-Location }

Start-Case 'init --prefix-width=0 is rejected'
Reset-UserHome
$projF8 = New-FreshProject
Push-Location $projF8
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 0 --max-work-item-lines 30 --review-per task
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr '--prefix-width must be positive'
} finally { Pop-Location }

Start-Case 'init --max-work-item-lines=-5 is rejected'
Reset-UserHome
$projF9 = New-FreshProject
Push-Location $projF9
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines=-5 --review-per task
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr '--max-work-item-lines must be positive'
} finally { Pop-Location }

Start-Case 'init --review-per (no value) is rejected'
Reset-UserHome
$projFa = New-FreshProject
Push-Location $projFa
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per ''
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr 'invalid --review-per'
} finally { Pop-Location }

# ---------- init interactive prompts (line-fed) ----------

Start-Case 'init interactive: default review-per (empty input → task)'
Reset-UserHome
$projI1 = New-FreshProject
Push-Location $projI1
try {
  # agents=1,2 (both), scope=1 (project), prefix-width=(default), max-work-item-lines=(default), review-per=(default=task)
  $Script:NextStdin = "1,2`n1`n`n`n`n"
  Invoke-XX init
  Assert-Eq 'exit 0' $RunRC 0
  $lockI1 = Get-Content -Raw -LiteralPath (Join-Path $projI1 $Script:STAX_LOCK_PATH)
  Assert-Contains 'default prefix_width' $lockI1 "`"prefix_width`": $DEFAULT_PREFIX_WIDTH"
  Assert-Contains 'default max_work_item_lines' $lockI1 '"max_work_item_lines": 30'
  Assert-Contains 'default review_per task' $lockI1 '"review_per": "task"'
} finally { Pop-Location }

Start-Case 'init interactive: review-per=2 (work-item) chosen via prompt'
Reset-UserHome
$projI2 = New-FreshProject
Push-Location $projI2
try {
  $Script:NextStdin = "1`n1`n`n`n2`n"
  Invoke-XX init
  Assert-Eq 'exit 0' $RunRC 0
  $lockI2 = Get-Content -Raw -LiteralPath (Join-Path $projI2 $Script:STAX_LOCK_PATH)
  Assert-Contains 'review_per work item via prompt' $lockI2 '"review_per": "work-item"'
} finally { Pop-Location }

Start-Case 'init interactive: custom prefix-width via prompt'
Reset-UserHome
$projI3 = New-FreshProject
Push-Location $projI3
try {
  $Script:NextStdin = "1`n1`n7`n42`n1`n"
  Invoke-XX init
  Assert-Eq 'exit 0' $RunRC 0
  $lockI3 = Get-Content -Raw -LiteralPath (Join-Path $projI3 $Script:STAX_LOCK_PATH)
  Assert-Contains 'prefix_width=7'    $lockI3 '"prefix_width": 7'
  Assert-Contains 'max_work_item_lines=42' $lockI3 '"max_work_item_lines": 42'
} finally { Pop-Location }

Start-Case 'init interactive: invalid scope choice exits non-zero'
Reset-UserHome
$projI4 = New-FreshProject
Push-Location $projI4
try {
  $Script:NextStdin = "1`n9`n`n`n`n"
  Invoke-XX init
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr 'invalid choice'
} finally { Pop-Location }

Start-Case 'init interactive: negative prefix-width via prompt rejected'
Reset-UserHome
$projI5 = New-FreshProject
Push-Location $projI5
try {
  $Script:NextStdin = "1`n1`n-3`n`n`n"
  Invoke-XX init
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr 'invalid prefix-width'
} finally { Pop-Location }

Start-Case 'init interactive: invalid review-per choice rejected'
Reset-UserHome
$projI6 = New-FreshProject
Push-Location $projI6
try {
  $Script:NextStdin = "1`n1`n`n`n9`n"
  Invoke-XX init
  Assert-Eq       'exit 1'     $RunRC 1
  Assert-Contains 'diagnostic' $RunErr 'invalid review-per'
} finally { Pop-Location }

# ---------- init JSON config file deep-merge on re-init ----------
#
# settings.json / hooks.json are JSON files that get DEEP-MERGED rather than
# overwritten when re-running init, per the configJSONExt branch in
# installAgentConfig. The user's scalar values win; bundled keys missing
# from the user file are added; arrays are unioned.
#
# A re-init on the same project is blocked by the lock-file check (already
# tested), so the merge path is exercised via INDEPENDENT projects: seed a
# pre-existing settings.json with user content, then run init.

Start-Case 'init seeds settings.json when absent'
Reset-UserHome
$projM1 = New-FreshProject
Push-Location $projM1
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'exit 0' $RunRC 0
  Assert-IsFile 'settings.json written' (Join-Path $projM1 $Script:CLAUDE_SETTINGS_PATH)
  $settings = Get-Content -Raw -LiteralPath (Join-Path $projM1 $Script:CLAUDE_SETTINGS_PATH)
  Assert-Contains 'hooks key present' $settings '"hooks"'
} finally { Pop-Location }

Start-Case 'init merges into an existing settings.json (user scalars survive)'
Reset-UserHome
$projM2 = New-FreshProject
$preDir = Join-Path $projM2 $CLAUDE_CONFIG_REL
New-Item -ItemType Directory -Force -Path $preDir | Out-Null
$preSettings = @'
{
  "fastMode": false,
  "model": "opus-4-7",
  "userKey": "preserved"
}
'@
Set-Content -LiteralPath (Join-Path $projM2 $Script:CLAUDE_SETTINGS_PATH) -Value $preSettings -Encoding ascii
Push-Location $projM2
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  $merged = Get-Content -Raw -LiteralPath (Join-Path $projM2 $Script:CLAUDE_SETTINGS_PATH)
  Assert-Contains 'user model preserved'    $merged '"opus-4-7"'
  Assert-Contains 'user fastMode=false preserved' $merged '"fastMode": false'
  Assert-Contains 'userKey preserved'       $merged '"userKey": "preserved"'
  Assert-Contains 'bundled hooks added'     $merged '"hooks"'
} finally { Pop-Location }

Start-Case 'init merges into a settings.json that already has a hooks array (union)'
Reset-UserHome
$projM3 = New-FreshProject
$preDir3 = Join-Path $projM3 $CLAUDE_CONFIG_REL
New-Item -ItemType Directory -Force -Path $preDir3 | Out-Null
$preSettings3 = @'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "my-custom-tool"}]
      }
    ]
  }
}
'@
Set-Content -LiteralPath (Join-Path $projM3 $Script:CLAUDE_SETTINGS_PATH) -Value $preSettings3 -Encoding ascii
Push-Location $projM3
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  $merged3 = Get-Content -Raw -LiteralPath (Join-Path $projM3 $Script:CLAUDE_SETTINGS_PATH)
  Assert-Contains 'user hook command preserved' $merged3 'my-custom-tool'
  Assert-Contains 'bundled hook landed'         $merged3 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'init merges into an empty settings.json file (seeds it)'
Reset-UserHome
$projM4 = New-FreshProject
$preDir4 = Join-Path $projM4 $CLAUDE_CONFIG_REL
New-Item -ItemType Directory -Force -Path $preDir4 | Out-Null
Set-Content -LiteralPath (Join-Path $projM4 $Script:CLAUDE_SETTINGS_PATH) -Value '' -Encoding ascii
Push-Location $projM4
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  $merged4 = Get-Content -Raw -LiteralPath (Join-Path $projM4 $Script:CLAUDE_SETTINGS_PATH)
  Assert-Contains 'empty file seeded with hooks' $merged4 '"hooks"'
} finally { Pop-Location }

Start-Case 'init merges into an existing codex hooks.json'
Reset-UserHome
$projM5 = New-FreshProject
$preDir5 = Join-Path $projM5 $CODEX_CONFIG_REL
New-Item -ItemType Directory -Force -Path $preDir5 | Out-Null
$preHooks5 = @'
{
  "userOnlyKey": true,
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "user-tool"}]
      }
    ]
  }
}
'@
Set-Content -LiteralPath (Join-Path $projM5 $Script:CODEX_HOOKS_PATH) -Value $preHooks5 -Encoding ascii
Push-Location $projM5
try {
  Invoke-XX init --scope project --agents codex `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  $merged5 = Get-Content -Raw -LiteralPath (Join-Path $projM5 $Script:CODEX_HOOKS_PATH)
  Assert-Contains 'user-only key preserved' $merged5 '"userOnlyKey": true'
  Assert-Contains 'user tool preserved'     $merged5 'user-tool'
  Assert-Contains 'bundled hook present'    $merged5 'stax work-items lint'
} finally { Pop-Location }

# ==========================================================================
# More Windows-specific cases (continuation)
# ==========================================================================

# ---------- skills remove unmerge: hook subtraction from settings.json ----------

Start-Case 'skills remove --project unmerges bundled hooks from settings.json'
Reset-UserHome
$projU1 = New-FreshProject
Push-Location $projU1
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'init exit 0' $RunRC 0
  $settingsPath = Join-Path $projU1 $Script:CLAUDE_SETTINGS_PATH
  # Seed a top-level scalar that lives OUTSIDE the bundled `hooks` subtree.
  # The un-merge must scope its subtraction to `hooks` only — any sibling
  # key (here: `userOnlyKey`) is user-owned and must survive verbatim. Bash
  # parity case at scripts/e2e_test.sh asserts this with `fastMode`.
  $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json -AsHashtable
  $settings.userOnlyKey = $true
  ($settings | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $settingsPath -Encoding ascii
  $beforeContent = Get-Content -Raw -LiteralPath $settingsPath
  Assert-Contains 'bundled hook present before remove' $beforeContent 'stax work-items lint'
  Assert-Contains 'top-level scalar present before remove' $beforeContent 'userOnlyKey'
  Invoke-XX skills remove --project
  Assert-Eq    'remove exit 0' $RunRC 0
  $afterContent = Get-Content -Raw -LiteralPath $settingsPath
  Assert-NotContains 'bundled hook removed'        $afterContent 'stax work-items lint'
  Assert-Contains    'top-level scalar survives'   $afterContent 'userOnlyKey'
} finally { Pop-Location }

# Parity with the bash case "skill remove --project un-merges bundled hook
# records" at scripts/e2e_test.sh: the bash version exercises BOTH the
# claude settings.json and the codex hooks.json in one shot. The PS1
# settings.json case sits above this block; this case is the missing
# codex half. Catches a regression where the un-merge walker stops
# after one agent's file or where the codex JSON shape (Stop hook
# without a matcher key) breaks subtractHooks.
Start-Case 'skills remove --project unmerges bundled hooks from codex hooks.json'
Reset-UserHome
$projU1Codex = New-FreshProject
Push-Location $projU1Codex
try {
  Invoke-XX init --scope project --agents codex `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'init exit 0' $RunRC 0
  $codexPath = Join-Path $projU1Codex $Script:CODEX_HOOKS_PATH
  # Seed a sibling user hook under the same event key (Stop) plus a
  # top-level scalar outside `hooks`. Both must survive the un-merge.
  $seeded = Get-Content -Raw -LiteralPath $codexPath | ConvertFrom-Json -AsHashtable
  $seeded.userOnlyKey = $true
  $userStop = @{ hooks = @(@{ type = 'command'; command = 'USER-CODEX-HOOK' }) }
  $seeded.hooks.Stop += $userStop
  ($seeded | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $codexPath -Encoding ascii
  $beforeCodex = Get-Content -Raw -LiteralPath $codexPath
  Assert-Contains 'bundled codex hook present before remove' $beforeCodex 'stax work-items lint 1>&2'
  Assert-Contains 'user codex hook present before remove'    $beforeCodex 'USER-CODEX-HOOK'
  Invoke-XX skills remove --project
  Assert-Eq    'remove exit 0' $RunRC 0
  $afterCodex = Get-Content -Raw -LiteralPath $codexPath
  Assert-NotContains 'bundled codex hook removed' $afterCodex 'stax work-items lint 1>&2'
  Assert-Contains    'user codex hook survived'   $afterCodex 'USER-CODEX-HOOK'
  Assert-Contains    'top-level scalar survives'  $afterCodex 'userOnlyKey'
} finally { Pop-Location }

Start-Case 'skills remove --project leaves user-tweaked hooks alone'
Reset-UserHome
$projU2 = New-FreshProject
Push-Location $projU2
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  # Modify the bundled hook command — now it's user-tweaked, deep-equal to
  # the shipped record fails, and the un-merge must leave it alone.
  $settingsPath2 = Join-Path $projU2 $Script:CLAUDE_SETTINGS_PATH
  (Get-Content -Raw -LiteralPath $settingsPath2).Replace('stax work-items lint', 'stax work-items lint --verbose') |
    Set-Content -LiteralPath $settingsPath2 -Encoding ascii
  Invoke-XX skills remove --project
  Assert-Eq 'remove exit 0' $RunRC 0
  $after2 = Get-Content -Raw -LiteralPath $settingsPath2
  Assert-Contains 'tweaked hook survived' $after2 'stax work-items lint --verbose'
} finally { Pop-Location }

Start-Case 'skills remove --project leaves user-authored hooks alone'
Reset-UserHome
$projU3 = New-FreshProject
Push-Location $projU3
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  $settingsPath3 = Join-Path $projU3 $Script:CLAUDE_SETTINGS_PATH
  # Append a wholly user-authored hook record.
  $existing = Get-Content -Raw -LiteralPath $settingsPath3 | ConvertFrom-Json -AsHashtable
  $userHook = @{ matcher = 'Bash'; hooks = @(@{ type = 'command'; command = 'user-only-tool' }) }
  $existing.hooks.PostToolUse += $userHook
  ($existing | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $settingsPath3 -Encoding ascii
  Invoke-XX skills remove --project
  Assert-Eq 'remove exit 0' $RunRC 0
  $after3 = Get-Content -Raw -LiteralPath $settingsPath3
  Assert-Contains    'user-only hook survived' $after3 'user-only-tool'
  Assert-NotContains 'bundled hook removed'    $after3 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'skills remove --project leaves user-authored sibling skills alongside ours'
Reset-UserHome
$projU4 = New-FreshProject
Push-Location $projU4
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  $sibling = Join-Path $projU4 (Join-Path $CLAUDE_SKILLS_REL 'my-private-skill')
  New-Item -ItemType Directory -Force -Path $sibling | Out-Null
  Set-Content -LiteralPath (Join-Path $sibling 'SKILL.md') -Value '# user skill' -Encoding ascii
  Invoke-XX skills remove --project
  Assert-Eq        'remove exit 0'              $RunRC 0
  Assert-NotExists 'stax skill removed'          (Join-Path $projU4 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  Assert-NotExists 'scope skill removed'       (Join-Path $projU4 (Join-Path $CLAUDE_SKILLS_REL $SKILL_SCOPE_DIR))
  Assert-IsDir     'sibling skill survived'     $sibling
  Assert-IsFile    'sibling SKILL.md survived'  (Join-Path $sibling 'SKILL.md')
} finally { Pop-Location }

Start-Case 'skills remove --user removes user-scope install end-to-end'
Reset-UserHome
# Fresh project dir so `stax init`'s cwd-local .stax/_config.lock seed
# does not trip the "already initialized" check against a leftover from
# an earlier case.
$projRMU = New-FreshProject
Push-Location $projRMU
try {
  Invoke-XX init --scope user --agents 'claude,codex' `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq    'init exit 0' $RunRC 0
  $preClaude = Join-Path $env:USERPROFILE (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR)
  $preCodex  = Join-Path $env:USERPROFILE (Join-Path $CODEX_SKILLS_REL  $SKILL_SHIP_DIR)
  Assert-IsDir 'pre-remove claude skill' $preClaude
  Assert-IsDir 'pre-remove codex skill'  $preCodex
  Invoke-XX skills remove --user
  Assert-Eq        'remove exit 0'   $RunRC 0
  Assert-NotExists 'claude removed'  $preClaude
  Assert-NotExists 'codex removed'   $preCodex
} finally { Pop-Location }

# ==========================================================================
# Cross-platform parity: Copilot CLI / OpenCode / Pi hook bundles.
# Mirrors the bash e2e cases under "Copilot CLI: hooks JSON install +
# scope-asymmetric paths", "OpenCode plugin: .ts whole-file install +
# remove", and "Pi extension: .ts whole-file install + remove". These
# are behavior-neutral JSON/byte assertions per the AGENTS.md Windows-
# parity rule — every case has a bash twin and the two must move
# together when the underlying behavior changes.
# ==========================================================================

Start-Case 'Copilot: init --scope project lands stax.json at .github\hooks\'
Reset-UserHome
$projCPp = New-FreshProject
Push-Location $projCPp
try {
  Invoke-XX init --scope project --agents copilot `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq      'exit 0' $RunRC 0
  $cpPath = Join-Path $projCPp (Join-Path $COPILOT_CONFIG_REL 'stax.json')
  Assert-IsFile  'stax.json present' $cpPath
  $body = Get-Content -Raw -LiteralPath $cpPath
  Assert-Contains 'version present'     $body '"version"'
  Assert-Contains 'postToolUse present' $body '"postToolUse"'
  Assert-Contains 'lint command present' $body 'stax work-items lint'
  $userScopePath = Join-Path $env:USERPROFILE (Join-Path $COPILOT_USER_CONFIG_REL 'stax.json')
  Assert-NotExists 'user-scope path empty after project install' $userScopePath
} finally { Pop-Location }

Start-Case 'Copilot: init --scope user lands stax.json at ~\.copilot\hooks\'
Reset-UserHome
$projCPu = New-FreshProject
Push-Location $projCPu
try {
  Invoke-XX init --scope user --agents copilot `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq      'exit 0' $RunRC 0
  $userPath = Join-Path $env:USERPROFILE (Join-Path $COPILOT_USER_CONFIG_REL 'stax.json')
  Assert-IsFile  'user stax.json present' $userPath
  $projPath = Join-Path $projCPu (Join-Path $COPILOT_CONFIG_REL 'stax.json')
  Assert-NotExists 'project-scope path empty after user install' $projPath
} finally { Pop-Location }

Start-Case 'Copilot: init re-run merges into edited stax.json'
Reset-UserHome
$projCPm = New-FreshProject
Push-Location $projCPm
try {
  Invoke-XX init --scope project --agents copilot `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'first init exit 0' $RunRC 0
  $cpPathM = Join-Path $projCPm (Join-Path $COPILOT_CONFIG_REL 'stax.json')
  $userEdit = @'
{
  "version": 1,
  "userOnlyKey": true,
  "hooks": {
    "postToolUse": [
      {"type": "command", "bash": "user-tool"}
    ]
  }
}
'@
  Set-Content -LiteralPath $cpPathM -Value $userEdit -Encoding ascii
  # Documented re-init flow — same as bash. Without removing the lock,
  # the second init aborts with "already initialized".
  Remove-Item -LiteralPath (Join-Path $projCPm $Script:STAX_LOCK_PATH) -Force
  Invoke-XX init --scope project --agents copilot `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $merged = Get-Content -Raw -LiteralPath $cpPathM
  Assert-Contains 'user scalar survives merge' $merged 'userOnlyKey'
  Assert-Contains 'user hook survives merge'   $merged 'user-tool'
  Assert-Contains 'bundled hook landed'        $merged 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'Copilot: skill remove --project un-merges bundled records'
Reset-UserHome
$projCPr = New-FreshProject
Push-Location $projCPr
try {
  Invoke-XX init --scope project --agents copilot `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $cpPathR = Join-Path $projCPr (Join-Path $COPILOT_CONFIG_REL 'stax.json')
  # Append a user-authored entry; un-merge drops only the bundled one.
  $augmented = @'
{
  "version": 1,
  "hooks": {
    "postToolUse": [
      {"type": "command", "bash": "stax work-items lint"},
      {"type": "command", "bash": "USER-COPILOT-HOOK"}
    ],
    "agentStop": [
      {"type": "command", "bash": "stax work-items lint"}
    ]
  }
}
'@
  Set-Content -LiteralPath $cpPathR -Value $augmented -Encoding ascii
  Invoke-XX skills remove --project
  Assert-Eq       'exit 0' $RunRC 0
  $after = Get-Content -Raw -LiteralPath $cpPathR
  Assert-NotContains 'bundled command gone'     $after 'stax work-items lint'
  Assert-Contains    'user copilot hook survives' $after 'USER-COPILOT-HOOK'
  Assert-Contains    'version scalar survives'   $after '"version"'
} finally { Pop-Location }

# ---------- OpenCode plugin: .ts whole-file install + remove ----------

Start-Case 'OpenCode: init lands stax.ts at .opencode\plugins\'
Reset-UserHome
$projOCp = New-FreshProject
Push-Location $projOCp
try {
  Invoke-XX init --scope project --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq      'exit 0' $RunRC 0
  $ocPath = Join-Path $projOCp (Join-Path $OPENCODE_CONFIG_REL 'stax.ts')
  Assert-IsFile  'stax.ts present' $ocPath
  $body = Get-Content -Raw -LiteralPath $ocPath
  Assert-Contains 'tool.execute.after present' $body 'tool.execute.after'
  Assert-Contains 'lint command in plugin'     $body 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'OpenCode: init re-run is byte-equal no-op'
Reset-UserHome
$projOCne = New-FreshProject
Push-Location $projOCne
try {
  Invoke-XX init --scope project --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $ocPathNe = Join-Path $projOCne (Join-Path $OPENCODE_CONFIG_REL 'stax.ts')
  $first = Get-Content -Raw -LiteralPath $ocPathNe
  Remove-Item -LiteralPath (Join-Path $projOCne $Script:STAX_LOCK_PATH) -Force
  Invoke-XX init --scope project --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $second = Get-Content -Raw -LiteralPath $ocPathNe
  Assert-Eq 'stax.ts content stable across re-runs' $first $second
} finally { Pop-Location }

Start-Case 'OpenCode: init preserves user-edited stax.ts'
Reset-UserHome
$projOCe = New-FreshProject
Push-Location $projOCe
try {
  Invoke-XX init --scope project --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $ocPathE = Join-Path $projOCe (Join-Path $OPENCODE_CONFIG_REL 'stax.ts')
  Add-Content -LiteralPath $ocPathE -Value '// I customized this'
  $userEdit = Get-Content -Raw -LiteralPath $ocPathE
  Remove-Item -LiteralPath (Join-Path $projOCe $Script:STAX_LOCK_PATH) -Force
  Invoke-XX init --scope project --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $after = Get-Content -Raw -LiteralPath $ocPathE
  Assert-Eq       'user edit survives re-run' $userEdit $after
  Assert-Contains 'stderr warned about skip'  $RunErr   'user-edited, skipping'
} finally { Pop-Location }

Start-Case 'OpenCode: skill remove deletes byte-equal stax.ts'
Reset-UserHome
$projOCr = New-FreshProject
Push-Location $projOCr
try {
  Invoke-XX init --scope project --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $ocPathR = Join-Path $projOCr (Join-Path $OPENCODE_CONFIG_REL 'stax.ts')
  Assert-IsFile 'stax.ts present before remove' $ocPathR
  Invoke-XX skills remove --project
  Assert-Eq        'exit 0' $RunRC 0
  Assert-NotExists 'stax.ts removed after byte-equal delete' $ocPathR
} finally { Pop-Location }

Start-Case 'OpenCode: skill remove preserves user-edited stax.ts'
Reset-UserHome
$projOCrEd = New-FreshProject
Push-Location $projOCrEd
try {
  Invoke-XX init --scope project --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $ocPathRe = Join-Path $projOCrEd (Join-Path $OPENCODE_CONFIG_REL 'stax.ts')
  Add-Content -LiteralPath $ocPathRe -Value '// I customized this'
  $userEdit = Get-Content -Raw -LiteralPath $ocPathRe
  Invoke-XX skills remove --project
  Assert-Eq 'exit 0' $RunRC 0
  $after = Get-Content -Raw -LiteralPath $ocPathRe
  Assert-Eq 'user-edited stax.ts survives remove' $userEdit $after
} finally { Pop-Location }

Start-Case 'OpenCode: --scope user lands stax.ts at ~\.config\opencode\plugins\'
Reset-UserHome
$projOCu = New-FreshProject
Push-Location $projOCu
try {
  Invoke-XX init --scope user --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq      'exit 0' $RunRC 0
  $userPath = Join-Path $env:USERPROFILE (Join-Path $OPENCODE_USER_CONFIG_REL 'stax.ts')
  Assert-IsFile  'user stax.ts present' $userPath
  $projPath = Join-Path $projOCu (Join-Path $OPENCODE_CONFIG_REL 'stax.ts')
  Assert-NotExists 'project-scope stax.ts empty after user install' $projPath
} finally { Pop-Location }

# ---------- Pi extension: .ts whole-file install + remove ----------

Start-Case 'Pi: init lands stax.ts at .pi\extensions\'
Reset-UserHome
$projPIp = New-FreshProject
Push-Location $projPIp
try {
  Invoke-XX init --scope project --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq      'exit 0' $RunRC 0
  $piPath = Join-Path $projPIp (Join-Path $PI_CONFIG_REL 'stax.ts')
  Assert-IsFile  'stax.ts present' $piPath
  $body = Get-Content -Raw -LiteralPath $piPath
  Assert-Contains 'tool_result handler'      $body 'tool_result'
  Assert-Contains 'session_shutdown handler' $body 'session_shutdown'
  Assert-Contains 'lint command in extension' $body 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'Pi: init re-run is byte-equal no-op'
Reset-UserHome
$projPIne = New-FreshProject
Push-Location $projPIne
try {
  Invoke-XX init --scope project --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $piPathNe = Join-Path $projPIne (Join-Path $PI_CONFIG_REL 'stax.ts')
  $first = Get-Content -Raw -LiteralPath $piPathNe
  Remove-Item -LiteralPath (Join-Path $projPIne $Script:STAX_LOCK_PATH) -Force
  Invoke-XX init --scope project --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $second = Get-Content -Raw -LiteralPath $piPathNe
  Assert-Eq 'stax.ts content stable across re-runs' $first $second
} finally { Pop-Location }

Start-Case 'Pi: init preserves user-edited stax.ts'
Reset-UserHome
$projPIe = New-FreshProject
Push-Location $projPIe
try {
  Invoke-XX init --scope project --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $piPathE = Join-Path $projPIe (Join-Path $PI_CONFIG_REL 'stax.ts')
  Add-Content -LiteralPath $piPathE -Value '// my customization'
  $userEdit = Get-Content -Raw -LiteralPath $piPathE
  Remove-Item -LiteralPath (Join-Path $projPIe $Script:STAX_LOCK_PATH) -Force
  Invoke-XX init --scope project --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $after = Get-Content -Raw -LiteralPath $piPathE
  Assert-Eq 'user-edited stax.ts survives re-run' $userEdit $after
} finally { Pop-Location }

Start-Case 'Pi: skill remove deletes byte-equal stax.ts'
Reset-UserHome
$projPIr = New-FreshProject
Push-Location $projPIr
try {
  Invoke-XX init --scope project --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $piPathR = Join-Path $projPIr (Join-Path $PI_CONFIG_REL 'stax.ts')
  Assert-IsFile 'stax.ts present before remove' $piPathR
  Invoke-XX skills remove --project
  Assert-Eq        'exit 0' $RunRC 0
  Assert-NotExists 'stax.ts removed after byte-equal delete' $piPathR
} finally { Pop-Location }

Start-Case 'Pi: skill remove preserves user-edited stax.ts'
Reset-UserHome
$projPIrEd = New-FreshProject
Push-Location $projPIrEd
try {
  Invoke-XX init --scope project --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $piPathRe = Join-Path $projPIrEd (Join-Path $PI_CONFIG_REL 'stax.ts')
  Add-Content -LiteralPath $piPathRe -Value '// pi customization'
  $userEdit = Get-Content -Raw -LiteralPath $piPathRe
  Invoke-XX skills remove --project
  Assert-Eq 'exit 0' $RunRC 0
  $after = Get-Content -Raw -LiteralPath $piPathRe
  Assert-Eq 'user-edited Pi stax.ts survives remove' $userEdit $after
} finally { Pop-Location }

Start-Case 'Pi: --scope user lands stax.ts at ~\.pi\agent\extensions\'
Reset-UserHome
$projPIu = New-FreshProject
Push-Location $projPIu
try {
  Invoke-XX init --scope user --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq      'exit 0' $RunRC 0
  $userPath = Join-Path $env:USERPROFILE (Join-Path $PI_USER_CONFIG_REL 'stax.ts')
  Assert-IsFile  'user stax.ts present' $userPath
  $projPath = Join-Path $projPIu (Join-Path $PI_CONFIG_REL 'stax.ts')
  Assert-NotExists 'project-scope stax.ts empty after user install' $projPath
} finally { Pop-Location }

# ---------- Google Antigravity: dual user-scope skills + JSON hooks ----------
#
# Behavior-neutral twins of the bash cases. Same install/un-merge contract:
# project scope lands skills at `.agents\skills\` and hooks at
# `.gemini\settings.json`; user scope writes skills to BOTH
# `~\.gemini\antigravity-cli\skills\` and `~\.gemini\config\skills\` plus
# hooks at `~\.gemini\settings.json`. The fact that one install drops
# skills into two user-scope discovery roots is the multi-destination
# `userSkillsRels` behavior — same code path as POSIX, just Windows path
# separators.

Start-Case 'Antigravity: init --scope project lands skills + settings.json'
Reset-UserHome
$projAG = New-FreshProject
Push-Location $projAG
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  foreach ($skill in $OWNED_SKILLS) {
    $sd = Join-Path $projAG (Join-Path $ANTIGRAVITY_SKILLS_REL $skill)
    Assert-IsDir  "project skill $skill" $sd
    Assert-IsFile "project SKILL.md $skill" (Join-Path $sd $SKILL_MANIFEST_FILE)
  }
  $settingsPath = Join-Path $projAG (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Assert-IsFile 'project settings.json present' $settingsPath
  $agBody = Get-Content -Raw -LiteralPath $settingsPath
  Assert-Contains 'hooks key present'   $agBody '"hooks"'
  Assert-Contains 'PostToolUse present' $agBody '"PostToolUse"'
  Assert-Contains 'Stop present'        $agBody '"Stop"'
  Assert-Contains 'lint command'        $agBody 'stax work-items lint'
  # User-scope paths must NOT have been touched by a project-scope install.
  $userCliSkill = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_CLI $SKILL_SCOPE_DIR)
  Assert-NotExists 'user-scope CLI skills empty after project install' $userCliSkill
  $userSharedSkill = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_SHARED $SKILL_SCOPE_DIR)
  Assert-NotExists 'user-scope shared skills empty after project install' $userSharedSkill
  $userSettings = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Assert-NotExists 'user-scope settings.json empty after project install' $userSettings
} finally { Pop-Location }

Start-Case 'Antigravity: init --scope user lands skills at BOTH user roots + settings.json'
Reset-UserHome
$projAGu = New-FreshProject
Push-Location $projAGu
try {
  Invoke-XX init --scope user --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  foreach ($skill in $OWNED_SKILLS) {
    $cliRoot = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_CLI $skill)
    Assert-IsDir  "CLI-local skill $skill" $cliRoot
    Assert-IsFile "CLI-local SKILL.md $skill" (Join-Path $cliRoot $SKILL_MANIFEST_FILE)
    $sharedRoot = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_SHARED $skill)
    Assert-IsDir  "shared skill $skill" $sharedRoot
    Assert-IsFile "shared SKILL.md $skill" (Join-Path $sharedRoot $SKILL_MANIFEST_FILE)
  }
  $userSettings = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Assert-IsFile 'user settings.json present' $userSettings
  $projSkill = Join-Path $projAGu (Join-Path $ANTIGRAVITY_SKILLS_REL $SKILL_SCOPE_DIR)
  Assert-NotExists 'project skills empty after user install' $projSkill
  $projSettings = Join-Path $projAGu (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Assert-NotExists 'project settings.json empty after user install' $projSettings
} finally { Pop-Location }

Start-Case 'Antigravity: init re-run merges into edited settings.json'
Reset-UserHome
$projAGm = New-FreshProject
Push-Location $projAGm
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'first init exit 0' $RunRC 0
  $agSettings = Join-Path $projAGm (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  $editedJson = @"
{
  "userOnlyKey": true,
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {"type": "command", "command": "USER-ANTIGRAVITY-HOOK"}
        ]
      }
    ]
  }
}
"@
  Set-Content -LiteralPath $agSettings -Value $editedJson -Encoding ascii
  Remove-Item -Force -LiteralPath (Join-Path $projAGm $STAX_LOCK_PATH)
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $agmBody = Get-Content -Raw -LiteralPath $agSettings
  Assert-Contains 'user scalar survives merge' $agmBody 'userOnlyKey'
  Assert-Contains 'user hook survives merge'   $agmBody 'USER-ANTIGRAVITY-HOOK'
  Assert-Contains 'bundled hook landed'        $agmBody 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'Antigravity: skill remove --project un-merges bundled records'
Reset-UserHome
$projAGr = New-FreshProject
Push-Location $projAGr
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $agSettings = Join-Path $projAGr (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  # Bundled records here MUST stay byte-equal to agents/antigravity/settings.json
  # — TestE2EHookFixtureMirrorsBundle pins this from the Go side against the
  # matching bash heredoc. Drift in one mirror is caught at unit-test speed.
  $seedJson = @"
{
  "userOnlyKey": true,
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {"type": "command", "command": "stax work-items lint"}
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          {"type": "command", "command": "USER-ANTIGRAVITY-HOOK"}
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "stax work-items lint"}
        ]
      }
    ]
  }
}
"@
  Set-Content -LiteralPath $agSettings -Value $seedJson -Encoding ascii
  Invoke-XX skills remove --project
  Assert-Eq 'exit 0' $RunRC 0
  $agrBody = Get-Content -Raw -LiteralPath $agSettings
  Assert-NotContains 'bundled command gone'         $agrBody 'stax work-items lint'
  Assert-Contains    'user antigravity hook survives' $agrBody 'USER-ANTIGRAVITY-HOOK'
  Assert-Contains    'user scalar survives un-merge'  $agrBody 'userOnlyKey'
  $projSkill = Join-Path $projAGr (Join-Path $ANTIGRAVITY_SKILLS_REL $SKILL_SCOPE_DIR)
  Assert-NotExists 'project skill scope dir gone' $projSkill
} finally { Pop-Location }

Start-Case 'Antigravity: skill remove --user clears both skills roots'
Reset-UserHome
$projAGru = New-FreshProject
Push-Location $projAGru
try {
  Invoke-XX init --scope user --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  # User-authored siblings in each user-scope root — the allowlist must
  # leave them alone while removing the bundled `scope` / `ship` dirs.
  $cliSibling = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_CLI 'my-skill')
  $sharedSibling = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_SHARED 'my-skill')
  New-Item -ItemType Directory -Force -Path $cliSibling | Out-Null
  New-Item -ItemType Directory -Force -Path $sharedSibling | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $cliSibling $SKILL_MANIFEST_FILE) | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $sharedSibling $SKILL_MANIFEST_FILE) | Out-Null
  Invoke-XX skills remove --user
  Assert-Eq 'exit 0' $RunRC 0
  foreach ($skill in $OWNED_SKILLS) {
    $cliPath = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_CLI $skill)
    Assert-NotExists "CLI-local $skill gone" $cliPath
    $sharedPath = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_SHARED $skill)
    Assert-NotExists "shared $skill gone" $sharedPath
  }
  Assert-IsDir 'user-authored sibling preserved (CLI root)'    $cliSibling
  Assert-IsDir 'user-authored sibling preserved (shared root)' $sharedSibling
} finally { Pop-Location }

Start-Case 'Antigravity: skills remove --user un-merges bundled hooks from user settings.json'
Reset-UserHome
$projAGruh = New-FreshProject
Push-Location $projAGruh
try {
  Invoke-XX init --scope user --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  # Sibling-case at line ~3743 above asserts the SKILL directories under
  # both user-scope roots get cleared. This case adds the missing
  # half: the user-scope settings.json gets un-merged the same way the
  # project-scope case (line ~3692) does. Without it, a regression
  # that broke `configRelFor(scopeUser)` for the antigravity row would
  # only surface when a Windows user noticed `~\.gemini\settings.json`
  # still carrying our hook records after `stax skills remove --user`.
  $userSettings = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  $augmented = @"
{
  "userOnlyKey": true,
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {"type": "command", "command": "stax work-items lint"}
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "USER-ANTIGRAVITY-USER-HOOK"}
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "stax work-items lint"}
        ]
      }
    ]
  }
}
"@
  Set-Content -LiteralPath $userSettings -Value $augmented -Encoding ascii
  Invoke-XX skills remove --user
  Assert-Eq 'remove exit 0' $RunRC 0
  $after = Get-Content -Raw -LiteralPath $userSettings
  Assert-NotContains 'user-scope bundled cmd gone'      $after 'stax work-items lint'
  Assert-Contains    'user-scope user antigravity hook' $after 'USER-ANTIGRAVITY-USER-HOOK'
  Assert-Contains    'user-scope scalar survives'       $after 'userOnlyKey'
} finally { Pop-Location }

# ---------- Antigravity: surgical merge / un-merge contract (PS1 twins) ----------
#
# Behavior-neutral mirrors of the bash cases that pin the JSON-merge
# contract for Antigravity. Same shape Claude / Codex / Copilot get on
# the PS1 side — every agent that rides the JSON-merge primitive gets
# its own cross-platform coverage, because a regression in the
# dispatch / extension / scope-resolution layer could break ONE agent
# without breaking another.

Start-Case 'Antigravity: init re-run is idempotent on merged settings.json'
Reset-UserHome
$projAGidem = New-FreshProject
Push-Location $projAGidem
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $agSettings = Join-Path $projAGidem (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Set-Content -LiteralPath $agSettings -Value '{"model": "gemini-2.5-pro"}' -Encoding ascii
  Remove-Item -Force -LiteralPath (Join-Path $projAGidem $STAX_LOCK_PATH)
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $snap1 = Get-Content -Raw -LiteralPath $agSettings
  Remove-Item -Force -LiteralPath (Join-Path $projAGidem $STAX_LOCK_PATH)
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $snap2 = Get-Content -Raw -LiteralPath $agSettings
  Assert-Eq 'settings.json idempotent across re-runs' $snap1 $snap2
} finally { Pop-Location }

Start-Case 'Antigravity: init re-run merge: hook arrays are unioned'
Reset-UserHome
$projAGarr = New-FreshProject
Push-Location $projAGarr
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $agSettings = Join-Path $projAGarr (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  $userArrJson = @"
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Read", "hooks": [{"type": "command", "command": "my-tool"}]}
    ]
  }
}
"@
  Set-Content -LiteralPath $agSettings -Value $userArrJson -Encoding ascii
  Remove-Item -Force -LiteralPath (Join-Path $projAGarr $STAX_LOCK_PATH)
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $arrBody = Get-Content -Raw -LiteralPath $agSettings
  Assert-Contains 'user matcher Read survives'              $arrBody '"matcher": "Read"'
  Assert-Contains 'user command my-tool survives'           $arrBody '"command": "my-tool"'
  Assert-Contains 'bundled matcher Write|Edit lands'        $arrBody '"matcher": "Write|Edit"'
  Assert-Contains 'bundled command stax work-items lint lands' $arrBody '"command": "stax work-items lint"'
} finally { Pop-Location }

Start-Case 'Antigravity: init re-run merge: user scalar wins on conflict'
Reset-UserHome
$projAGscalar = New-FreshProject
Push-Location $projAGscalar
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $agSettings = Join-Path $projAGscalar (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Set-Content -LiteralPath $agSettings -Value '{"model": "gemini-3-flash", "hooks": {}}' -Encoding ascii
  Remove-Item -Force -LiteralPath (Join-Path $projAGscalar $STAX_LOCK_PATH)
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $scalarBody = Get-Content -Raw -LiteralPath $agSettings
  Assert-Contains 'user model scalar preserved' $scalarBody '"model": "gemini-3-flash"'
  Assert-Contains 'bundled hooks still added'   $scalarBody 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'Antigravity: init re-run merge: malformed JSON preserves user bytes'
Reset-UserHome
$projAGbad = New-FreshProject
Push-Location $projAGbad
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $agSettings = Join-Path $projAGbad (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Set-Content -LiteralPath $agSettings -Value 'not valid json {' -Encoding ascii
  Remove-Item -Force -LiteralPath (Join-Path $projAGbad $STAX_LOCK_PATH)
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0 despite parse failure' $RunRC 0
  # Get-Content -Raw returns the file's full bytes; Set-Content adds a
  # trailing CRLF on Windows that bash's `$(cat ...)` strips, so trim
  # before comparing to keep the assertion behavior-neutral across
  # platforms. The contract under test is "merge failure doesn't
  # rewrite the user's content", not "the user's content has a
  # specific trailing newline".
  Assert-Eq 'malformed file untouched' (Get-Content -Raw -LiteralPath $agSettings).TrimEnd() 'not valid json {'
  Assert-Contains 'stderr warns about merge failure' $RunErr 'merge failed'
} finally { Pop-Location }

Start-Case 'Antigravity: init re-run merge: empty existing file is seeded'
Reset-UserHome
$projAGempty = New-FreshProject
Push-Location $projAGempty
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $agSettings = Join-Path $projAGempty (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Set-Content -LiteralPath $agSettings -Value '' -Encoding ascii
  Remove-Item -Force -LiteralPath (Join-Path $projAGempty $STAX_LOCK_PATH)
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $emptyBody = Get-Content -Raw -LiteralPath $agSettings
  Assert-Contains 'empty file gained hooks key'    $emptyBody '"hooks"'
  Assert-Contains 'empty file gained bundled hook' $emptyBody 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'Antigravity: init re-run keeps user-authored sibling skills'
Reset-UserHome
$projAGsib = New-FreshProject
Push-Location $projAGsib
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $sibDir = Join-Path $projAGsib (Join-Path $ANTIGRAVITY_SKILLS_REL 'my-custom')
  New-Item -ItemType Directory -Force -Path $sibDir | Out-Null
  $sibManifest = Join-Path $sibDir $SKILL_MANIFEST_FILE
  Set-Content -LiteralPath $sibManifest -Value 'MINE' -Encoding ascii
  Remove-Item -Force -LiteralPath (Join-Path $projAGsib $STAX_LOCK_PATH)
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  Assert-IsFile 'sibling antigravity skill survives re-run' $sibManifest
  Assert-IsDir  ('bundled ' + $SKILL_SHIP_DIR + ' present after re-run') `
      (Join-Path $projAGsib (Join-Path $ANTIGRAVITY_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'Antigravity: skill remove leaves foreign content under .gemini alone'
Reset-UserHome
$projAGrmi = New-FreshProject
Push-Location $projAGrmi
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $configDir = Join-Path $projAGrmi $ANTIGRAVITY_CONFIG_REL
  $notesDir  = Join-Path $configDir 'notes'
  New-Item -ItemType Directory -Force -Path $notesDir | Out-Null
  Set-Content -LiteralPath (Join-Path $configDir 'GEMINI.md')   -Value 'USER' -Encoding ascii
  Set-Content -LiteralPath (Join-Path $notesDir 'note.txt')     -Value 'USER' -Encoding ascii
  $skillsDir = Join-Path $projAGrmi $ANTIGRAVITY_SKILLS_REL
  Set-Content -LiteralPath (Join-Path $skillsDir 'STRAY.md')    -Value 'USER' -Encoding ascii
  Invoke-XX skills remove --project
  Assert-Eq 'exit 0' $RunRC 0
  $kept = @(
    (Join-Path $ANTIGRAVITY_CONFIG_REL 'GEMINI.md'),
    (Join-Path $ANTIGRAVITY_CONFIG_REL (Join-Path 'notes' 'note.txt')),
    (Join-Path $ANTIGRAVITY_SKILLS_REL 'STRAY.md'),
    $STAX_LOCK_PATH,
    $STAX_SYSTEMS_PATH
  )
  foreach ($rel in $kept) {
    Assert-IsFile ('skill remove kept ' + $rel) (Join-Path $projAGrmi $rel)
  }
  foreach ($skill in $OWNED_SKILLS) {
    Assert-NotExists ('skill remove dropped ' + $ANTIGRAVITY_SKILLS_REL + '/' + $skill) `
        (Join-Path $projAGrmi (Join-Path $ANTIGRAVITY_SKILLS_REL $skill))
  }
} finally { Pop-Location }

Start-Case 'Antigravity: skill remove preserves user-tweaked variant of a bundled record'
Reset-UserHome
$projAGunt = New-FreshProject
Push-Location $projAGunt
try {
  Invoke-XX init --scope project --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $agSettings = Join-Path $projAGunt (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  # `--verbose` suffix breaks deep-equality with the bundle — the record
  # MUST survive un-merge because ownership is the leaf record, not the
  # matcher or event key.
  $tweakedJson = @"
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "stax work-items lint --verbose"}]}
    ]
  }
}
"@
  Set-Content -LiteralPath $agSettings -Value $tweakedJson -Encoding ascii
  Invoke-XX skills remove --project
  Assert-Eq 'exit 0' $RunRC 0
  $tweakedBody = Get-Content -Raw -LiteralPath $agSettings
  Assert-Contains 'tweaked matcher kept' $tweakedBody 'Write|Edit'
  Assert-Contains 'tweaked command kept' $tweakedBody 'stax work-items lint --verbose'
} finally { Pop-Location }

Start-Case 'Antigravity: init --scope user re-run merges edited settings.json'
Reset-UserHome
$projAGumerge = New-FreshProject
Push-Location $projAGumerge
try {
  Invoke-XX init --scope user --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $userSettings = Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_CONFIG_REL 'settings.json')
  Set-Content -LiteralPath $userSettings -Value '{"USER": "EDIT", "model": "gemini-3-pro"}' -Encoding ascii
  Remove-Item -Force -LiteralPath (Join-Path $projAGumerge $STAX_LOCK_PATH)
  Invoke-XX init --scope user --agents antigravity `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  $userBody = Get-Content -Raw -LiteralPath $userSettings
  Assert-Contains 'user-scope settings.json keeps USER key' $userBody '"USER": "EDIT"'
  Assert-Contains 'user-scope settings.json keeps model'    $userBody '"model": "gemini-3-pro"'
  Assert-Contains 'user-scope settings.json gains hook'     $userBody 'stax work-items lint'
  foreach ($skill in $OWNED_SKILLS) {
    Assert-IsFile ('user-scope CLI ' + $skill + ' after merge re-run') `
        (Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_CLI (Join-Path $skill $SKILL_MANIFEST_FILE)))
    Assert-IsFile ('user-scope shared ' + $skill + ' after merge re-run') `
        (Join-Path $env:USERPROFILE (Join-Path $ANTIGRAVITY_USER_SKILLS_REL_SHARED (Join-Path $skill $SKILL_MANIFEST_FILE)))
  }
} finally { Pop-Location }

# ---------- Windows-specific: PATH separator + drive letters ----------

Start-Case 'install_local.ps1 puts the binary under %USERPROFILE%\.stax'
Reset-UserHome
# Simulate having a fresh local build in bin/ — copy the e2e build into
# %REPO_ROOT%\bin\stax-windows-amd64.exe so the local installer can find it.
$binDir = Join-Path $RepoRoot 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$arch = if ([Environment]::Is64BitProcess) { 'amd64' } else { 'amd64' }
$localBin = Join-Path $binDir "stax-windows-$arch.exe"
Copy-Item -Force -LiteralPath $Script:BuildBin -Destination $localBin
Push-Location $RepoRoot
try {
  & pwsh -NoLogo -NonInteractive -File (Join-Path $RepoRoot 'scripts\install_local.ps1') 2>&1 | Out-Null
  $installed = Join-Path $env:USERPROFILE '.stax\stax.exe'
  Assert-IsFile 'binary at $HOME\.stax\stax.exe' $installed
} finally {
  Pop-Location
  Remove-Item -Force -LiteralPath $localBin -ErrorAction SilentlyContinue
}

# ---------- Windows-specific: file-attribute / hidden ----------

Start-Case 'work-items list does NOT special-case hidden files (returns them in walk output)'
$projH = New-FreshProject
Initialize-ProjectScaffold $projH
$staxDirH = Join-Path $projH $STAX_DIR
Write-Plan $staxDirH '0001-keep.md' 'valid' 'auth'
# listPlans walks via os.ReadDir + a filename-regex match; it does not
# consult the Win32 hidden attribute. A user who hides a work-item file for
# their own organizational reasons should still see it in `work-items list`,
# matching POSIX dotfile-handling semantics elsewhere in the CLI.
$hidden = Join-Path $staxDirH '0002-hidden.md'
Write-Plan $staxDirH '0002-hidden.md' 'valid' 'auth'
(Get-Item -LiteralPath $hidden).Attributes = 'Hidden'
Push-Location $projH
try {
  Invoke-XX work-items list
  Assert-Eq        'exit 0' $RunRC 0
  Assert-Contains  'visible work item listed' $RunOut '0001-keep'
  Assert-Contains  'hidden work item also listed' $RunOut '0002-hidden'
} finally { Pop-Location }

# ---------- Windows-specific: read-only files ----------

Start-Case 'work-items lint reads a read-only work-item file successfully'
$projRO = New-FreshProject
Initialize-ProjectScaffold $projRO
Write-Registry (Join-Path $projRO $STAX_DIR) 'Auth Service'
Write-FullPlan (Join-Path $projRO $STAX_DIR) '0001-foo.md' 'valid' 'auth-service' 'Auth Service'
$roPath = Join-Path (Join-Path $projRO $STAX_DIR) '0001-foo.md'
(Get-Item -LiteralPath $roPath).Attributes = 'ReadOnly'
Push-Location $projRO
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 0'  $RunRC 0
  Assert-Contains 'ok line' $RunOut '0001-foo.md: ok'
} finally {
  (Get-Item -LiteralPath $roPath).Attributes = 'Normal'
  Pop-Location
}

# ---------- Windows-specific: short (8.3) path tolerance ----------

Start-Case 'init survives in a path created via 8.3 short form (best-effort)'
Reset-UserHome
# 8.3 names are auto-generated by NTFS when 8dot3 creation is enabled
# (registry key HKLM\System\CurrentControlSet\Control\FileSystem\
# NtfsDisable8dot3NameCreation = 0). On a runner with 8dot3 disabled the
# Scripting.FileSystemObject returns the long path unchanged — in that
# case the test marks itself as a visible skip so the run summary reports
# "N skipped" and a config regression that flips this off is impossible
# to miss.
$candidate = Join-Path $ProjectsRoot 'a-folder-with-very-long-name-for-8dot3'
New-Item -ItemType Directory -Force -Path $candidate | Out-Null
$shortPath = try {
  $fs = New-Object -ComObject Scripting.FileSystemObject
  $fs.GetFolder($candidate).ShortPath
} catch { $null }
if ($shortPath -and $shortPath -ne $candidate) {
  Push-Location $shortPath
  try {
    Invoke-XX init --scope project --agents claude `
                      --prefix-width 4 --max-work-item-lines 30 --review-per task
    Assert-Eq    'exit 0' $RunRC 0
    Assert-IsDir 'install at long-name resolution' (Join-Path $candidate (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
  } finally { Pop-Location }
} else {
  Write-Skip '8.3 short-path generation unavailable on this volume (NtfsDisable8dot3NameCreation likely set)'
}

# ---------- Windows-specific: trailing whitespace + odd characters in args ----------

Start-Case 'work-items slugify handles a title with leading/trailing whitespace'
Invoke-XX work-items slugify '   Foo Bar   '
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'whitespace stripped' $RunOut 'foo-bar'

Start-Case 'work-items slugify handles a title with embedded tab characters'
Invoke-XX work-items slugify "Foo`tBar`tBaz"
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'tabs collapsed to single dash' $RunOut 'foo-bar-baz'

Start-Case 'work-items slugify handles a title with embedded newlines'
Invoke-XX work-items slugify "Foo`nBar"
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'newline collapsed to single dash' $RunOut 'foo-bar'

Start-Case 'work-items slugify accepts a title with leading dashes after --'
Invoke-XX work-items slugify -- '-leading-dash-title'
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'leading dashes trimmed' $RunOut 'leading-dash-title'

Start-Case 'work-items slugify drops non-ASCII characters'
Invoke-XX work-items slugify 'café Søk'
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'non-ASCII collapsed' $RunOut 'caf-s-k'

Start-Case 'work-items slugify rejects wholly non-ASCII titles as unsluggable'
Invoke-XX work-items slugify '日本語'
Assert-Eq       'exit 2'     $RunRC 2
Assert-Contains 'diagnostic' $RunErr 'no slug-able characters'

# ---------- Windows-specific: idempotent re-bootstrap of ~/.stax/agents ----------

Start-Case 'stax --version repopulates ~/.stax/agents/ when manually deleted'
Reset-UserHome
Invoke-XX --version
Assert-Eq    'first run exit 0' $RunRC 0
Assert-IsDir 'agents dir present' (Join-Path $env:USERPROFILE $STAX_AGENTS_DIR)
Remove-Item -Recurse -Force -LiteralPath (Join-Path $env:USERPROFILE $STAX_AGENTS_DIR)
Assert-NotExists 'agents dir manually deleted' (Join-Path $env:USERPROFILE $STAX_AGENTS_DIR)
Invoke-XX --version
Assert-Eq    'second run exit 0' $RunRC 0
Assert-IsDir 'agents dir restored' (Join-Path $env:USERPROFILE $STAX_AGENTS_DIR)
foreach ($skill in $OWNED_SKILLS) {
  Assert-IsDir "skill $skill repopulated" (Join-Path $env:USERPROFILE (Join-Path $STAX_AGENTS_SKILLS_DIR $skill))
}

# ---------- Windows-specific: project-marker-check diagnostic is path-free ----------

Start-Case 'project-marker-check diagnostic uses generic wording on Windows too'
$noProjW = New-FreshProject
Push-Location $noProjW
try {
  Invoke-XX work-items next-prefix
  Assert-Eq       'exit 2'     $RunRC 2
  Assert-Contains 'banner'     $RunErr 'not a stax project'
  Assert-NotContains 'no work-items-dir leak'  $RunErr $STAX_DIR
  Assert-NotContains 'no stax init mention is ok' $RunErr 'C:\'
} finally { Pop-Location }

# ---------- Windows-specific: lock-file parsing tolerates extra whitespace ----------

Start-Case 'work-items next-prefix tolerates pretty-printed _config.lock'
$projWS = New-FreshProject
Initialize-ProjectScaffold $projWS
$lockWS = Join-Path (Join-Path $projWS $STAX_DIR) $STAX_LOCK_FILE
$prettyLock = @"
{
    "prefix_width": 5,
    "max_work_item_lines": 25,
    "review_per": "work-item"
}
"@
Set-Content -LiteralPath $lockWS -Value $prettyLock -Encoding ascii
Push-Location $projWS
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq '5-wide first prefix' $RunOut '00001'
} finally { Pop-Location }

# ---------- Windows-specific: malformed _config.lock falls back to defaults ----------

Start-Case 'work-items next-prefix falls back to default on malformed _config.lock'
$projMal = New-FreshProject
Initialize-ProjectScaffold $projMal
$lockMal = Join-Path (Join-Path $projMal $STAX_DIR) $STAX_LOCK_FILE
Set-Content -LiteralPath $lockMal -Value '{this is not json' -Encoding ascii
Push-Location $projMal
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'falls back to defaultPrefixWidth' $RunOut '0001'
} finally { Pop-Location }

# ---------- Windows-specific: zero prefix_width falls back to default ----------

Start-Case 'work-items next-prefix falls back when prefix_width is non-positive'
$projZ = New-FreshProject
Initialize-ProjectScaffold $projZ
$lockZ = Join-Path (Join-Path $projZ $STAX_DIR) $STAX_LOCK_FILE
Set-Content -LiteralPath $lockZ -Value '{"prefix_width": 0}' -Encoding ascii
Push-Location $projZ
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'fall back on prefix_width=0' $RunOut '0001'
} finally { Pop-Location }

# ---------- Windows-specific: work-items list with no work items returns empty ----------

Start-Case 'work-items list on fresh project returns empty output (no rows, no error)'
$projEmpty = New-FreshProject
Initialize-ProjectScaffold $projEmpty
Push-Location $projEmpty
try {
  Invoke-XX work-items list
  Assert-Eq 'exit 0'   $RunRC 0
  Assert-Eq 'empty stdout' $RunOut ''
} finally { Pop-Location }

Start-Case 'work-items list --order=asc on fresh project returns empty'
Push-Location $projEmpty
try {
  Invoke-XX work-items list --order=asc
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'empty asc'  $RunOut ''
} finally { Pop-Location }

Start-Case 'work-items lint on fresh project returns 0 with 0 ok'
Push-Location $projEmpty
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 0'                $RunRC 0
  Assert-Contains 'summary on empty proj' $RunErr '0 ok'
} finally { Pop-Location }

# ---------- Windows-specific: extra long titles & filenames ----------

Start-Case 'work-items slugify produces a slug for a 200-char title'
$longTitle = ('Lorem ' * 40).TrimEnd()
Invoke-XX work-items slugify $longTitle
Assert-Eq 'exit 0' $RunRC 0
Assert-Contains 'slug starts with lorem' $RunOut 'lorem'

Start-Case 'work-items list ignores a filename with a 200-char slug if the prefix format is right'
# A 200-char slug + the sandbox prefix exceeds MAX_PATH=260 on Windows
# unless LongPathsEnabled is set (registry key HKLM\System\
# CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1). On a runner
# without it the Write-Plan call fails; in that case the test marks itself
# as a visible skip rather than silently passing with no assertion run.
$projLong = New-FreshProject
Initialize-ProjectScaffold $projLong
$staxDirLong = Join-Path $projLong $STAX_DIR
$longSlug = 'aaaaaaaaaa' * 20  # 200 chars
$longName = "0001-$longSlug.md"
$longFull = Join-Path $staxDirLong $longName
$wroteLong = $false
try {
  Write-Plan $staxDirLong $longName 'valid' 'auth'
  $wroteLong = $true
} catch {}
if ($wroteLong) {
  Push-Location $projLong
  try {
    Invoke-XX work-items list
    Assert-Eq 'exit 0' $RunRC 0
    # The long-name row should appear in the output as-is.
    Assert-Contains 'long-slug row present' $RunOut '0001-aaaaaaaaaa'
  } finally { Pop-Location }
} else {
  Write-Skip 'long-path file creation failed; LongPathsEnabled likely off (registry)'
}

# ---------- Windows-specific: --version vs bare stax have DIFFERENT contracts ----------
#
# `--version` is the seed-and-exit driver: prints the installer-parseable
# notice on stdout and returns. Bare `stax` (and `stax --no-browser`)
# launches the loopback HTTP server and blocks on the listener — the
# captured stdout starts with the "listening on …" banner, not the
# version notice. Pin the divergence so a future refactor that re-unifies
# them is caught.

Start-Case 'stax --version differs from the bare-stax server banner'
Reset-UserHome
Invoke-XX --version
$versionOut = $RunOut
# Bare `stax --no-browser` gates on `.stax/_config.lock`; seed a fresh
# project so the listener actually binds. Without --cwd + scaffold the
# server would exit 2 with the init banner and Start-StaxServer would
# (correctly) report "process exited before listening".
$projBanner = New-FreshProject
Initialize-ProjectScaffold -Path $projBanner
$srv = Start-StaxServer --no-browser --cwd $projBanner
try {
  $serverBanner = Get-Content -LiteralPath $srv.StaxStdout -Raw
  Assert-Contains '--version prints notice'             $versionOut 'Stax by Stackific'
  Assert-NotContains '--version is not the server banner' $versionOut $srv.StaxUrl
  Assert-Contains 'server prints listening banner'      $serverBanner $srv.StaxUrl
  Assert-NotContains 'server is not the version notice' $serverBanner 'Stax by Stackific'
} finally {
  Stop-StaxServer -Process $srv
}

# ==========================================================================
# Additional lint, list, skills-remove, and Windows-specific cases
# ==========================================================================

# ---------- work-items lint: more edge cases ----------

Start-Case 'work-items lint flags an empty systems array'
$projEM = New-FreshProject
Initialize-ProjectScaffold $projEM
Write-Registry (Join-Path $projEM $STAX_DIR) 'Auth Service'
$staxDirEM = Join-Path $projEM $STAX_DIR
$bodyEmptySys = @"
---
title: foo
status: valid
systems: []
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirEM '0001-foo.md') -Value $bodyEmptySys -Encoding ascii
Push-Location $projEM
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                $RunRC 1
  Assert-Contains 'empty systems finding' $RunOut '`systems:` array is empty'
} finally { Pop-Location }

Start-Case 'work-items lint rejects block-form systems frontmatter'
$projBF = New-FreshProject
Initialize-ProjectScaffold $projBF
Write-Registry (Join-Path $projBF $STAX_DIR) 'Auth Service'
$staxDirBF = Join-Path $projBF $STAX_DIR
$bodyBlock = @"
---
title: foo
status: valid
systems:
  - auth-service
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirBF '0001-foo.md') -Value $bodyBlock -Encoding ascii
Push-Location $projBF
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'                  $RunRC 1
  Assert-Contains 'block-form rejected'     $RunOut 'must be inline array'
} finally { Pop-Location }

Start-Case 'work-items lint flags a work item missing the ## Tasks section'
$projNT = New-FreshProject
Initialize-ProjectScaffold $projNT
Write-Registry (Join-Path $projNT $STAX_DIR) 'Auth Service'
$staxDirNT = Join-Path $projNT $STAX_DIR
$bodyNoTasks = @"
---
title: foo
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A
"@
Set-Content -LiteralPath (Join-Path $staxDirNT '0001-foo.md') -Value $bodyNoTasks -Encoding ascii
Push-Location $projNT
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'              $RunRC 1
  Assert-Contains 'missing Tasks'       $RunOut 'missing required section "## Tasks"'
} finally { Pop-Location }

Start-Case 'work-items lint flags a work item missing the ## Approach section'
$projNA = New-FreshProject
Initialize-ProjectScaffold $projNA
Write-Registry (Join-Path $projNA $STAX_DIR) 'Auth Service'
$staxDirNA = Join-Path $projNA $STAX_DIR
$bodyNoAppr = @"
---
title: foo
status: valid
systems: [auth-service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirNA '0001-foo.md') -Value $bodyNoAppr -Encoding ascii
Push-Location $projNA
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'              $RunRC 1
  Assert-Contains 'missing Approach'    $RunOut 'missing required section "## Approach"'
} finally { Pop-Location }

Start-Case 'work-items lint passes bidirectional extends when both sides linked'
$projBE = New-FreshProject
Initialize-ProjectScaffold $projBE
Write-Registry (Join-Path $projBE $STAX_DIR) 'Auth Service'
$staxDirBE = Join-Path $projBE $STAX_DIR
$bodyExtender = @"
---
title: foo
status: valid
systems: [auth-service]
extends: [0002-bar]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
$bodyExtended = @"
---
title: bar
status: valid
systems: [auth-service]
extended_by: [0001-foo]
created: 2026-05-22T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
"@
Set-Content -LiteralPath (Join-Path $staxDirBE '0001-foo.md') -Value $bodyExtender -Encoding ascii
Set-Content -LiteralPath (Join-Path $staxDirBE '0002-bar.md') -Value $bodyExtended -Encoding ascii
Push-Location $projBE
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 0'    $RunRC 0
  Assert-Contains 'summary'   $RunErr '2 ok'
} finally { Pop-Location }

Start-Case 'work-items lint accumulates multiple findings on one file'
$projMF = New-FreshProject
Initialize-ProjectScaffold $projMF
Write-Registry (Join-Path $projMF $STAX_DIR) 'Auth Service'
$staxDirMF = Join-Path $projMF $STAX_DIR
# Multiple violations: bad status, bad created, missing ## Tasks.
$bodyMulti = @"
---
title: foo
status: bogus
systems: [auth-service]
created: yesterday
---

## Goal
g

## Approach
- A
"@
Set-Content -LiteralPath (Join-Path $staxDirMF '0001-foo.md') -Value $bodyMulti -Encoding ascii
Push-Location $projMF
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'              $RunRC 1
  Assert-Contains 'status finding'      $RunOut '"bogus"'
  Assert-Contains 'created finding'     $RunOut '"yesterday"'
  Assert-Contains 'missing Tasks'       $RunOut 'missing required section "## Tasks"'
} finally { Pop-Location }

Start-Case 'work-items lint reports per-file summary line on stderr'
$projSM = New-FreshProject
Initialize-ProjectScaffold $projSM
Write-Registry (Join-Path $projSM $STAX_DIR) 'Auth Service'
Write-FullPlan (Join-Path $projSM $STAX_DIR) '0001-foo.md' 'valid' 'auth-service' 'Auth Service'
Write-FullPlan (Join-Path $projSM $STAX_DIR) '0002-bar.md' 'valid' 'auth-service' 'Auth Service'
$staxDirSM = Join-Path $projSM $STAX_DIR
# Wreck one work item with a known-bad status to force "1 ok, 1 failed".
$badContent = (Get-Content -Raw -LiteralPath (Join-Path $staxDirSM '0002-bar.md')) -replace 'status: valid', 'status: bogus'
Set-Content -LiteralPath (Join-Path $staxDirSM '0002-bar.md') -Value $badContent -Encoding ascii
Push-Location $projSM
try {
  Invoke-XX work-items lint
  Assert-Eq       'exit 1'               $RunRC 1
  Assert-Contains '1 ok, 1 failed'       $RunErr '1 ok, 1 failed'
  Assert-Contains 'first work item ok line'   $RunOut '0001-foo.md: ok'
} finally { Pop-Location }

Start-Case 'work-items lint rejects positional arguments'
Push-Location $projSM
try {
  Invoke-XX work-items lint extra-arg
  Assert-Eq       'exit 2'        $RunRC 2
  Assert-Contains 'takes no args' $RunErr 'takes no arguments'
} finally { Pop-Location }

# ---------- work-items list: more filtering edge cases ----------

Start-Case 'work-items list --status nonexistent returns zero rows'
$projXS = New-FreshProject
Initialize-ProjectScaffold $projXS
Write-Plan (Join-Path $projXS $STAX_DIR) '0001-alpha.md' 'valid' 'auth'
Push-Location $projXS
try {
  Invoke-XX work-items list --status nope
  Assert-Eq 'exit 0'    $RunRC 0
  Assert-Eq 'no rows'   $RunOut ''
} finally { Pop-Location }

Start-Case 'work-items list keeps comma-list of statuses without duplicates'
$projDS = New-FreshProject
Initialize-ProjectScaffold $projDS
Write-Plan (Join-Path $projDS $STAX_DIR) '0001-alpha.md' 'valid' 'auth'
Write-Plan (Join-Path $projDS $STAX_DIR) '0002-bravo.md' 'valid' 'auth'
Push-Location $projDS
try {
  Invoke-XX work-items list --status 'valid,valid'
  Assert-Eq 'exit 0' $RunRC 0
  $expected = @("0002-bravo`tvalid`tauth", "0001-alpha`tvalid`tauth") -join "`n"
  Assert-Eq 'dup statuses collapsed' $RunOut $expected
} finally { Pop-Location }

Start-Case 'work-items list skips a work item with missing status:'
$projMS = New-FreshProject
Initialize-ProjectScaffold $projMS
$staxDirMS = Join-Path $projMS $STAX_DIR
$bodyNoStatus = @"
---
title: foo
systems: [auth]
---
"@
Set-Content -LiteralPath (Join-Path $staxDirMS '0001-broken.md') -Value $bodyNoStatus -Encoding ascii
Write-Plan $staxDirMS '0002-ok.md' 'valid' 'auth'
Push-Location $projMS
try {
  Invoke-XX work-items list
  Assert-Eq       'exit 0'             $RunRC 0
  Assert-Eq       'only ok work item'       $RunOut "0002-ok`tvalid`tauth"
  Assert-Contains 'warning on broken'  $RunErr '0001-broken.md'
} finally { Pop-Location }

Start-Case 'work-items list skips a work item with missing systems:'
$projMSY = New-FreshProject
Initialize-ProjectScaffold $projMSY
$staxDirMSY = Join-Path $projMSY $STAX_DIR
$bodyNoSys = @"
---
title: foo
status: valid
---
"@
Set-Content -LiteralPath (Join-Path $staxDirMSY '0001-broken.md') -Value $bodyNoSys -Encoding ascii
Write-Plan $staxDirMSY '0002-ok.md' 'valid' 'auth'
Push-Location $projMSY
try {
  Invoke-XX work-items list
  Assert-Eq       'exit 0'                 $RunRC 0
  Assert-Eq       'only ok work item'           $RunOut "0002-ok`tvalid`tauth"
  Assert-Contains 'warning on broken'      $RunErr '0001-broken.md'
} finally { Pop-Location }

Start-Case 'work-items list emits status verbatim (does not normalize case)'
$projCS = New-FreshProject
Initialize-ProjectScaffold $projCS
$staxDirCS = Join-Path $projCS $STAX_DIR
# Use lowercase 'valid' — anything other than the three allowed values gets
# warned by listPlans (no — only lint enforces allowedness, list emits as-is)
Write-Plan $staxDirCS '0001-alpha.md' 'valid' 'auth'
Push-Location $projCS
try {
  Invoke-XX work-items list
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Contains 'lowercase status emitted'   $RunOut 'valid'
} finally { Pop-Location }

# ---------- work-items next-prefix: edge cases ----------

Start-Case 'work-items next-prefix ignores files whose prefix differs from configured width'
$projWX = New-FreshProject
Initialize-ProjectScaffold $projWX
$staxDirWX = Join-Path $projWX $STAX_DIR
# Default width is 4. A 5-digit-prefixed file should be invisible to the
# 4-wide regex scan.
Write-Plan $staxDirWX '0003-three.md'  'valid' 'auth'
Write-Plan $staxDirWX '00099-extra.md' 'valid' 'auth'
Push-Location $projWX
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'next after 0003 (not 00099)' $RunOut '0004'
} finally { Pop-Location }

Start-Case 'work-items next-prefix ignores directories that match the prefix format'
$projDX = New-FreshProject
Initialize-ProjectScaffold $projDX
$staxDirDX = Join-Path $projDX $STAX_DIR
Write-Plan $staxDirDX '0001-foo.md' 'valid' 'auth'
# A subdir with the prefix format but no `.md` extension. scanHighestPrefix's
# regex is `^\d{N}-.+\.md$`, so this directory entry can't match and must be
# silently ignored. Only 0001-foo.md remains as the recognized work item, so the
# next prefix is 0002.
New-Item -ItemType Directory -Force -Path (Join-Path $staxDirDX '0050-bar') | Out-Null
Push-Location $projDX
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0' $RunRC 0
  Assert-Eq 'directory ignored, next after 0001-foo.md' $RunOut '0002'
} finally { Pop-Location }

# ---------- skills remove: idempotency + cross-scope ----------

Start-Case 'skills remove --project is idempotent (second run no-op)'
Reset-UserHome
$projID = New-FreshProject
Push-Location $projID
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  Invoke-XX skills remove --project
  Assert-Eq 'first remove exit 0' $RunRC 0
  Invoke-XX skills remove --project
  Assert-Eq       'second remove exit 0' $RunRC 0
  Assert-Contains 'summary line on second run' $RunOut 'Removed 0'
} finally { Pop-Location }

Start-Case 'skills remove --user after a --project install is a silent no-op'
Reset-UserHome
$projXP = New-FreshProject
Push-Location $projXP
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  Invoke-XX skills remove --user
  Assert-Eq       'exit 0'                    $RunRC 0
  Assert-Contains 'summary line: Removed 0'   $RunOut 'Removed 0'
  # The project install is untouched by --user remove.
  Assert-IsDir 'project skill still present' (Join-Path $projXP (Join-Path $CLAUDE_SKILLS_REL $SKILL_SHIP_DIR))
} finally { Pop-Location }

Start-Case 'skills remove --user touches user-scope hooks.json (codex)'
Reset-UserHome
# Fresh project dir so `stax init`'s cwd-local .stax/_config.lock seed
# does not trip the "already initialized" check against a leftover from
# an earlier case.
$projRMHC = New-FreshProject
Push-Location $projRMHC
try {
  Invoke-XX init --scope user --agents codex `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  $userHooks = Join-Path $env:USERPROFILE (Join-Path $CODEX_CONFIG_REL $CODEX_HOOKS_FILE)
  $beforeContent = Get-Content -Raw -LiteralPath $userHooks
  Assert-Contains 'bundled hook present pre-remove' $beforeContent 'stax work-items lint'
  Invoke-XX skills remove --user
  Assert-Eq 'remove exit 0' $RunRC 0
  $afterContent = Get-Content -Raw -LiteralPath $userHooks
  Assert-NotContains 'bundled hook removed' $afterContent 'stax work-items lint'
} finally { Pop-Location }

# ---------- skills remove --user covers every hook-shipping agent (bash parity) ----------
#
# The bash twin to this block lives under "skills remove --user
# un-merges hooks from every shipped config" in scripts/e2e_test.sh.
# The codex case above (line ~4296) already covers one of the five
# hook-shipping agents; this block adds the four it missed: claude
# (settings.json under ~/.claude), copilot (stax.json under
# ~/.copilot/hooks/ via userConfigRel — the scope-asymmetric path),
# opencode (stax.ts under ~/.config/opencode/plugins/), and pi
# (stax.ts under ~/.pi/agent/extensions/). Each one: install --scope
# user, mutate to add a user-authored record / variant, run `skills
# remove --user`, assert ours-gone / user-stays.

Start-Case 'skills remove --user un-merges bundled hooks from user settings.json (claude)'
Reset-UserHome
$projRUCl = New-FreshProject
Push-Location $projRUCl
try {
  Invoke-XX init --scope user --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  $userClaudeSettings = Join-Path $env:USERPROFILE $Script:CLAUDE_SETTINGS_PATH
  $augmented = @'
{
  "fastMode": true,
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "stax work-items lint"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "USER-CLAUDE-USER-HOOK"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "stax work-items lint"}]}
    ]
  }
}
'@
  Set-Content -LiteralPath $userClaudeSettings -Value $augmented -Encoding ascii
  Invoke-XX skills remove --user
  Assert-Eq 'remove exit 0' $RunRC 0
  $after = Get-Content -Raw -LiteralPath $userClaudeSettings
  Assert-Contains    'user-scope fastMode kept'            $after '"fastMode": true'
  Assert-Contains    'user-scope Bash record survives'     $after 'USER-CLAUDE-USER-HOOK'
  Assert-NotContains 'user-scope bundled command gone'     $after 'stax work-items lint'
} finally { Pop-Location }

Start-Case 'skills remove --user un-merges bundled hooks from user Copilot stax.json'
Reset-UserHome
$projRUCp = New-FreshProject
Push-Location $projRUCp
try {
  Invoke-XX init --scope user --agents copilot `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  # Copilot's userConfigRel diverts the user-scope install to
  # `.copilot\hooks\` (NOT `.github\hooks\`). This is the only path
  # that exercises the scope-asymmetric resolver end-to-end on Windows.
  $userCpPath = Join-Path $env:USERPROFILE (Join-Path $COPILOT_USER_CONFIG_REL 'stax.json')
  Assert-IsFile 'user copilot stax.json present' $userCpPath
  $augmented = @'
{
  "version": 1,
  "hooks": {
    "postToolUse": [
      {"type": "command", "bash": "stax work-items lint"},
      {"type": "command", "bash": "USER-COPILOT-USER-HOOK"}
    ],
    "agentStop": [
      {"type": "command", "bash": "stax work-items lint"}
    ]
  }
}
'@
  Set-Content -LiteralPath $userCpPath -Value $augmented -Encoding ascii
  Invoke-XX skills remove --user
  Assert-Eq 'remove exit 0' $RunRC 0
  $after = Get-Content -Raw -LiteralPath $userCpPath
  Assert-Contains    'user-scope copilot user hook survives' $after 'USER-COPILOT-USER-HOOK'
  Assert-NotContains 'user-scope copilot bundled cmd gone'   $after 'stax work-items lint'
  Assert-Contains    'user-scope copilot version preserved'  $after '"version"'
} finally { Pop-Location }

Start-Case 'skills remove --user deletes byte-equal user OpenCode stax.ts'
Reset-UserHome
$projRUOc = New-FreshProject
Push-Location $projRUOc
try {
  Invoke-XX init --scope user --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  $userOcPath = Join-Path $env:USERPROFILE (Join-Path $OPENCODE_USER_CONFIG_REL 'stax.ts')
  Assert-IsFile 'user opencode stax.ts present' $userOcPath
  Invoke-XX skills remove --user
  Assert-Eq        'remove exit 0' $RunRC 0
  Assert-NotExists 'user opencode stax.ts removed (byte-equal)' $userOcPath
} finally { Pop-Location }

Start-Case 'skills remove --user preserves user-edited OpenCode stax.ts'
Reset-UserHome
$projRUOcE = New-FreshProject
Push-Location $projRUOcE
try {
  Invoke-XX init --scope user --agents opencode `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $userOcPathE = Join-Path $env:USERPROFILE (Join-Path $OPENCODE_USER_CONFIG_REL 'stax.ts')
  Add-Content -LiteralPath $userOcPathE -Value '// my user-scope customization'
  $userEdited = Get-Content -Raw -LiteralPath $userOcPathE
  Invoke-XX skills remove --user
  Assert-Eq 'remove exit 0' $RunRC 0
  $after = Get-Content -Raw -LiteralPath $userOcPathE
  Assert-Eq 'user-edited user-scope OpenCode stax.ts survives' $userEdited $after
} finally { Pop-Location }

Start-Case 'skills remove --user deletes byte-equal user Pi stax.ts'
Reset-UserHome
$projRUPi = New-FreshProject
Push-Location $projRUPi
try {
  Invoke-XX init --scope user --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'init exit 0' $RunRC 0
  $userPiPath = Join-Path $env:USERPROFILE (Join-Path $PI_USER_CONFIG_REL 'stax.ts')
  Assert-IsFile 'user pi stax.ts present' $userPiPath
  Invoke-XX skills remove --user
  Assert-Eq        'remove exit 0' $RunRC 0
  Assert-NotExists 'user pi stax.ts removed (byte-equal)' $userPiPath
} finally { Pop-Location }

Start-Case 'skills remove --user preserves user-edited Pi stax.ts'
Reset-UserHome
$projRUPiE = New-FreshProject
Push-Location $projRUPiE
try {
  Invoke-XX init --scope user --agents pi `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  $userPiPathE = Join-Path $env:USERPROFILE (Join-Path $PI_USER_CONFIG_REL 'stax.ts')
  Add-Content -LiteralPath $userPiPathE -Value '// pi user-scope customization'
  $userEdited = Get-Content -Raw -LiteralPath $userPiPathE
  Invoke-XX skills remove --user
  Assert-Eq 'remove exit 0' $RunRC 0
  $after = Get-Content -Raw -LiteralPath $userPiPathE
  Assert-Eq 'user-edited user-scope Pi stax.ts survives' $userEdited $after
} finally { Pop-Location }

# ---------- Windows-specific: encoding and output stability ----------

Start-Case 'work-items list stdout has no UTF-8 BOM'
$projUB = New-FreshProject
Initialize-ProjectScaffold $projUB
Write-Plan (Join-Path $projUB $STAX_DIR) '0001-alpha.md' 'valid' 'auth'
Push-Location $projUB
try {
  $tmpStdout = [System.IO.Path]::GetTempFileName()
  try {
    & $Script:BuildBin work-items list > $tmpStdout
    $bytes = [System.IO.File]::ReadAllBytes($tmpStdout)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
      Write-Fail 'stdout has unexpected BOM'
    } else {
      Write-Pass 'stdout is BOM-free'
    }
  } finally {
    Remove-Item -Force -LiteralPath $tmpStdout -ErrorAction SilentlyContinue
  }
} finally { Pop-Location }

Start-Case 'work-items list uses LF line endings (not CRLF) on stdout'
Push-Location $projUB
try {
  Write-Plan (Join-Path $projUB $STAX_DIR) '0002-bravo.md' 'valid' 'auth'
  $tmpStdout2 = [System.IO.Path]::GetTempFileName()
  try {
    & $Script:BuildBin work-items list > $tmpStdout2
    $bytes2 = [System.IO.File]::ReadAllBytes($tmpStdout2)
    # Wrap in @(...) so .Count is always defined — pwsh leaves a single-
    # or zero-element pipeline result as a scalar / $null, on which .Count
    # would throw ParentContainsErrorRecordException.
    $crCount = @($bytes2 | Where-Object { $_ -eq 0x0D }).Count
    # Go's fmt.Println always writes \n. On Windows, the runtime does NOT
    # translate to CRLF for binary stdout. Document the contract.
    Assert-Eq 'no CR bytes in stdout' $crCount 0
  } finally {
    Remove-Item -Force -LiteralPath $tmpStdout2 -ErrorAction SilentlyContinue
  }
} finally { Pop-Location }

Start-Case 'work-items list stdout is exactly one trailing newline per row'
$projNL = New-FreshProject
Initialize-ProjectScaffold $projNL
$staxDirNL = Join-Path $projNL $STAX_DIR
Write-Plan $staxDirNL '0001-alpha.md' 'valid' 'auth'
Write-Plan $staxDirNL '0002-bravo.md' 'valid' 'auth'
Push-Location $projNL
try {
  $tmpStdout3 = [System.IO.Path]::GetTempFileName()
  try {
    & $Script:BuildBin work-items list > $tmpStdout3
    $bytes3 = [System.IO.File]::ReadAllBytes($tmpStdout3)
    $lfCount = @($bytes3 | Where-Object { $_ -eq 0x0A }).Count
    Assert-Eq 'one LF per row (no extras)' $lfCount 2
  } finally {
    Remove-Item -Force -LiteralPath $tmpStdout3 -ErrorAction SilentlyContinue
  }
} finally { Pop-Location }

# ---------- Windows-specific: invoking through cmd.exe vs pwsh parity ----------

Start-Case 'work-items next-prefix output is identical whether invoked via pwsh or cmd.exe'
$projXP = New-FreshProject
Initialize-ProjectScaffold $projXP
Write-Plan (Join-Path $projXP $STAX_DIR) '0007-foo.md' 'valid' 'auth'
Push-Location $projXP
try {
  $pwshOut = (& $Script:BuildBin work-items next-prefix).Trim()
  $cmdOut  = (& cmd.exe /c "`"$Script:BuildBin`" work-items next-prefix").Trim()
  Assert-Eq 'pwsh and cmd outputs match' $pwshOut $cmdOut
} finally { Pop-Location }

# ---------- Windows-specific: arg passing with quotes / spaces ----------

Start-Case 'work-items slugify handles quoted title with embedded spaces (pwsh)'
Invoke-XX work-items slugify 'Hello   World'
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'multi-space slug' $RunOut 'hello-world'

Start-Case 'work-items slugify handles a title containing single quotes'
Invoke-XX work-items slugify "It's a Test"
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'apostrophe collapsed to dash' $RunOut 'it-s-a-test'

Start-Case 'work-items slugify handles a title containing double quotes'
# In pwsh, double quotes inside single-quoted strings are literal.
Invoke-XX work-items slugify 'Quote "this" please'
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'double-quotes collapsed' $RunOut 'quote-this-please'

Start-Case 'work-items slugify handles a title containing path separators'
Invoke-XX work-items slugify 'a\b/c'
Assert-Eq 'exit 0' $RunRC 0
Assert-Eq 'separators collapsed' $RunOut 'a-b-c'

# ---------- Windows-specific: init does not leave bin\ pollution at project root ----------

Start-Case 'init does not drop binary artifacts in the project root'
Reset-UserHome
$projNB = New-FreshProject
Push-Location $projNB
try {
  Invoke-XX init --scope project --agents claude `
                    --prefix-width 4 --max-work-item-lines 30 --review-per task
  Assert-Eq 'exit 0' $RunRC 0
  Assert-NotExists 'no stax at project root'     (Join-Path $projNB 'stax')
  Assert-NotExists 'no stax.exe at project root' (Join-Path $projNB 'stax.exe')
  Assert-NotExists 'no bin/ at project root'    (Join-Path $projNB 'bin')
} finally { Pop-Location }

# ---------- Windows-specific: ignore file flagged as system ----------

Start-Case 'work-items list ignores .DS_Store-like cruft at the .stax/ root'
$projDS = New-FreshProject
Initialize-ProjectScaffold $projDS
$staxDirDSL = Join-Path $projDS $STAX_DIR
Write-Plan $staxDirDSL '0001-foo.md' 'valid' 'auth'
Set-Content -LiteralPath (Join-Path $staxDirDSL 'Thumbs.db') -Value 'binary cruft' -Encoding ascii
Set-Content -LiteralPath (Join-Path $staxDirDSL 'desktop.ini') -Value '[.ShellClassInfo]' -Encoding ascii
Push-Location $projDS
try {
  Invoke-XX work-items list
  Assert-Eq       'exit 0'                $RunRC 0
  Assert-Eq       'only matching work item'    $RunOut "0001-foo`tvalid`tauth"
  Assert-NotContains 'Thumbs.db not warned'  $RunErr 'Thumbs.db'
  Assert-NotContains 'desktop.ini not warned' $RunErr 'desktop.ini'
} finally { Pop-Location }

# ---------- Windows-specific: --help equivalent forms ----------

Start-Case 'stax --help renders the same notice as -h'
Invoke-XX --help
$helpOut = $RunOut
Invoke-XX -h
Assert-Eq 'parity between --help and -h' $RunOut $helpOut

# ---------- Windows-specific: work-items next-prefix never panics on empty proj dir ----------

Start-Case 'work-items next-prefix returns 0001 when .stax/ has only the scaffold files'
$projOS = New-FreshProject
Initialize-ProjectScaffold $projOS
Push-Location $projOS
try {
  Invoke-XX work-items next-prefix
  Assert-Eq 'exit 0'        $RunRC 0
  Assert-Eq 'first prefix'  $RunOut '0001'
} finally { Pop-Location }

# ==========================================================================
# Summary
# ==========================================================================

Write-Host ''
Write-Host ('-' * 40)
Write-Host ("e2e: {0} passed, {1} failed, {2} skipped" -f $PassCount, $FailCount, $SkipCount)

if ($FailCount -gt 0) {
  exit 1
}
exit 0
