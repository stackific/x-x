#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# e2e_test.sh — End-to-end test driver for the stax CLI.
#
# Builds the binary, installs it into an isolated HOME, then exercises every
# subcommand, every flag combination, and every documented side effect.
# Designed to run inside the Linux container launched by .github/workflows/
# test.yml, but also runnable locally on macOS / Linux:
#
#   ./scripts/e2e_test.sh
#
# Exits 0 on success, 1 on the first assertion failure (each failure prints
# the offending line + actual/expected so logs are self-diagnosing).

set -u  # NB: no -e — assertion helpers handle failure reporting themselves.

# ---------- path constants (mirror of constants.go) ----------
#
# AGENTS.md hard rule: every on-disk path component referenced by *any*
# source — Go or shell — flows from a single source of truth (constants.go).
# This block is the shell mirror; constants_e2e_test.go re-reads this file
# at `go test` time and fails on byte-level drift from the matching Go
# constant. Add/rename a path in constants.go → mirror it here in the
# same change.

readonly STAX_DIR=".stax"                          # staxDir
readonly STAX_CONFIG_FILE=".config.json"           # staxConfigFile
readonly AGENTS_EMBED_ROOT="agents"                # agentsEmbedRoot
readonly SKILLS_SUBDIR="skills"                    # skillsSubdir
readonly STAX_LOCK_FILE="_config.lock"             # staxLockFile
readonly STAX_SYSTEMS_FILE="_data_systems.yaml"    # staxSystemsFile
readonly DEFAULT_PREFIX_WIDTH=4                    # defaultPrefixWidth
readonly WORK_ITEMS_LIST_OVERFLOW_THRESHOLD=20          # workItemsListOverflowThreshold

# Local-server constants. Mirrors of serverListenAddr / serverDisplayURL
# / apiHelloPath / apiSystemsPath in constants.go. The
# TestE2EShellConstantsMatchGo drift check re-reads this block at
# `go test` time and fails on byte-level divergence from the Go side.
readonly STAX_SERVER_LISTEN_ADDR="127.0.0.1:7829"   # serverListenAddr (bind)
readonly STAX_SERVER_DISPLAY_URL="http://localhost:7829"  # serverDisplayURL (user-facing)
readonly STAX_API_STATS_PATH="/api/stats"           # apiStatsPath
readonly STAX_API_SYSTEMS_PATH="/api/systems"       # apiSystemsPath

# Bundled skill directory names (skill*Dir in constants.go).
readonly SKILL_SCOPE_DIR="scope"                   # skillScopeDir
readonly SKILL_SHIP_DIR="ship"                     # skillShipDir
readonly SKILL_MANIFEST_FILE="SKILL.md"            # skillManifestFile

# ownedSkills, flattened to a space-separated list for `for` iteration.
readonly OWNED_SKILLS="${SKILL_SCOPE_DIR} ${SKILL_SHIP_DIR}"

# Mirrors of agentTargets[*].skillsRel / userSkillsRel / configRel in
# constants.go. The registry is sorted alphabetically by display name
# (case-insensitive) and looked up by `key` in the Go drift check
# (TestE2EShellConstantsMatchGo), so these readonly entries are matched
# by NAME, not by index. Codex, Copilot, Pi, omp, and Zed all resolve
# skills from `.agents/skills` at workspace scope (cross-agent open
# spec, install is idempotent so the rows co-exist on disk without
# conflict). Cline does NOT use the cross-agent path — per
# docs.cline.bot/customization/overview it reads from `.cline/skills/`
# (project) and `~/.cline/skills/` (user) only. OpenCode and Claude
# stay on their own paths because their lookup logic doesn't include
# `.agents/skills` — OpenCode reads `.opencode/{command,commands}/` only,
# Claude reads `.claude/skills/` only. Cursor diverges across scopes
# (workspace `.agents/skills`, global `~/.cursor/skills`) and is
# represented in Go via agentTarget.userSkillsRel.
readonly CLAUDE_SKILLS_REL=".claude/skills"
readonly CLAUDE_CONFIG_REL=".claude"
readonly CLINE_SKILLS_REL=".cline/skills"
readonly CODEX_SKILLS_REL=".agents/skills"
readonly CODEX_CONFIG_REL=".codex"
readonly CONTINUE_SKILLS_REL=".continue/skills"
readonly CURSOR_SKILLS_REL=".agents/skills"
readonly CURSOR_USER_SKILLS_REL=".cursor/skills"
readonly COPILOT_SKILLS_REL=".agents/skills"
# Copilot is scope-asymmetric on hook paths: `.github/hooks/` at project
# (lives inside the repo so it's checked in next to other GitHub config),
# `~/.copilot/hooks/` at user. The `userConfigRel` field on the Copilot
# agentTargets row carries the user-scope override; this pair of
# mirrored constants surfaces both halves so the harness can assert
# install + un-merge at each scope without rebuilding the path inline.
readonly COPILOT_CONFIG_REL=".github/hooks"
readonly COPILOT_USER_CONFIG_REL=".copilot/hooks"
# Google Antigravity ships skills at `.agents/skills/` at project scope
# (cross-agent open spec, identical to Codex/Copilot/Pi/omp/Zed) AND
# installs into TWO user-scope discovery roots in one shot:
# `~/.gemini/antigravity-cli/skills/` (read by the Antigravity CLI `agy`)
# and `~/.gemini/config/skills/` (shared across the Antigravity tool
# family — read by both the CLI and the Antigravity Desktop app, mirroring
# `~/.gemini/config/mcp_config.json`'s shared-config role). Hooks land in
# `.gemini/settings.json` at both scopes (configRel == userConfigRel),
# under the same `{"hooks": {...}}` schema Claude Code's settings.json
# uses — the agent layer reads project `.gemini/settings.json` with user
# `~/.gemini/settings.json` as fallback, the precedence Antigravity
# inherits from Gemini CLI.
readonly ANTIGRAVITY_SKILLS_REL=".agents/skills"
readonly ANTIGRAVITY_USER_SKILLS_REL_CLI=".gemini/antigravity-cli/skills"
readonly ANTIGRAVITY_USER_SKILLS_REL_SHARED=".gemini/config/skills"
readonly ANTIGRAVITY_CONFIG_REL=".gemini"
readonly KILO_SKILLS_REL=".kilocode/skills"
readonly OMP_SKILLS_REL=".agents/skills"
readonly OPENCODE_SKILLS_REL=".opencode/commands"
# OpenCode's hook surface is a TypeScript plugin file, NOT a JSON
# config — it gets installed via the .ts whole-file-ownership branch
# in installOneAgentConfigFile. Project scope and user scope diverge
# on the directory (`.opencode/plugins/` vs `~/.config/opencode/plugins/`)
# the same way Copilot's hooks do.
readonly OPENCODE_CONFIG_REL=".opencode/plugins"
readonly OPENCODE_USER_CONFIG_REL=".config/opencode/plugins"
readonly PI_SKILLS_REL=".agents/skills"
# Pi extensions: TypeScript modules, same install branch as OpenCode.
# Pi's user-scope path nests under `.pi/agent/` (Pi's per-agent state
# tree) rather than `.pi/` directly, so the pair diverges on the
# parent directory too — track both halves.
readonly PI_CONFIG_REL=".pi/extensions"
readonly PI_USER_CONFIG_REL=".pi/agent/extensions"
readonly ZED_SKILLS_REL=".agents/skills"
# Continue / Cursor / Kilo / omp / Zed each ship no per-agent config
# (configSrc / configRel are empty), so no *_CONFIG_REL mirrors are
# needed for them. Copilot / OpenCode / Pi have *_CONFIG_REL +
# *_USER_CONFIG_REL pairs declared further up.
# Parent of CODEX_SKILLS_REL — used by isolation cases that seed sibling
# files alongside the Codex skills dir. Derived (not a Go constant) to
# avoid drift if the skillsRel ever moves.
readonly CODEX_SKILLS_PARENT="${CODEX_SKILLS_REL%/*}"
# Parent of OPENCODE_SKILLS_REL — used by reset_user_home to wipe the
# whole .opencode/ tree between cases. Derived for the same drift reason.
readonly OPENCODE_SKILLS_PARENT="${OPENCODE_SKILLS_REL%/*}"
# Parent of CLINE_SKILLS_REL — wiped between cases. Cline owns its own
# `.cline/` dir at both project and user scope.
readonly CLINE_SKILLS_PARENT="${CLINE_SKILLS_REL%/*}"
# Parents for the rest of the per-agent roots. Each is wiped between
# cases via reset_user_home so a previous case's install never bleeds
# into the next.
readonly CONTINUE_SKILLS_PARENT="${CONTINUE_SKILLS_REL%/*}"
readonly CURSOR_USER_SKILLS_PARENT="${CURSOR_USER_SKILLS_REL%/*}"
readonly KILO_SKILLS_PARENT="${KILO_SKILLS_REL%/*}"
# Parents of the per-agent hook destinations at user scope. Each is
# wiped by reset_user_home so a previous case's bundled hook never
# survives into the next.
readonly COPILOT_USER_CONFIG_PARENT="${COPILOT_USER_CONFIG_REL%/*}"
readonly OPENCODE_USER_CONFIG_PARENT="${OPENCODE_USER_CONFIG_REL%/*}"
readonly PI_USER_CONFIG_PARENT="${PI_USER_CONFIG_REL%/*}"
# Antigravity's user-scope footprint nests every destination under a single
# `.gemini/` root: both skills paths (`.gemini/antigravity-cli/skills`,
# `.gemini/config/skills`) and the hooks file (`.gemini/settings.json`).
# Wiping ANTIGRAVITY_USER_HOME_PARENT alone covers all three between
# cases — no per-leaf cleanup needed.
readonly ANTIGRAVITY_USER_HOME_PARENT="${ANTIGRAVITY_CONFIG_REL}"

# Bundle-provided config filenames (agents/<configSrc>/* in the embed). Not
# named in constants.go (the embed tree is the source) but pinned here
# because the e2e asserts on their post-install presence.
readonly CLAUDE_SETTINGS_FILE="settings.json"
readonly CODEX_HOOKS_FILE="hooks.json"

# skipFromEmbed entry — the one file the embed walk omits.
readonly EMBED_README="README.md"

# Build stamp consumed by version-format assertions.
readonly E2E_VERSION="v0.0.0-e2e"

# Compositions so call sites read as plain English.
readonly STAX_AGENTS_DIR="${STAX_DIR}/${AGENTS_EMBED_ROOT}"
readonly STAX_AGENTS_SKILLS_DIR="${STAX_AGENTS_DIR}/${SKILLS_SUBDIR}"
readonly STAX_LOCK_PATH="${STAX_DIR}/${STAX_LOCK_FILE}"
readonly STAX_SYSTEMS_PATH="${STAX_DIR}/${STAX_SYSTEMS_FILE}"
readonly CLAUDE_SETTINGS_PATH="${CLAUDE_CONFIG_REL}/${CLAUDE_SETTINGS_FILE}"
readonly CODEX_HOOKS_PATH="${CODEX_CONFIG_REL}/${CODEX_HOOKS_FILE}"

# ---------- locations ----------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d -t stax-e2e.XXXXXX)"
# Build artifact lives inside the sandbox so nothing lands in the repo's
# working tree. The sandbox is wiped on exit via the trap below.
BUILD_BIN="${SANDBOX}/stax-e2e"
# Cleanup must tolerate read-only files (e.g. the Go module cache) the test
# might have populated. chmod is best-effort; rm always runs.
trap 'chmod -R +w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX" 2>/dev/null' EXIT

# Sandbox HOME for all CLI invocations. We only switch HOME AFTER the build
# step so that `go build` uses the developer's real module cache instead of
# repopulating one inside the sandbox (which would also slow CI down).
SANDBOX_HOME="$SANDBOX/home"
mkdir -p "$SANDBOX_HOME"

PROJECTS_ROOT="$SANDBOX/projects"
mkdir -p "$PROJECTS_ROOT"

# Suppress anonymous-usage telemetry for the entire e2e run. The CI
# runner sets CI=true, which the telemetry layer would normally tag
# events with — but we don't want test traffic mixed into the
# production telemetry stream. DO_NOT_TRACK is the industry-standard
# env that every reasonable telemetry layer honors; DISABLE_TELEMETRY
# is the project-specific belt-and-braces escape hatch.
export DO_NOT_TRACK=1
export DISABLE_TELEMETRY=1

# ---------- pretty + assertion helpers ----------

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_CASE=""

case_start() { CURRENT_CASE="$1"; printf '\n=== %s ===\n' "$1"; }
ok()   { PASS_COUNT=$((PASS_COUNT + 1)); printf '  ok   %s\n' "$1"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [ $# -ge 2 ]; then
    printf '       %s\n' "$2" >&2
  fi
}

assert_eq() {
  # assert_eq <label> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "got=$2 want=$3"; fi
}
assert_contains() {
  # assert_contains <label> <haystack> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      fail "$1" "needle '$3' not in: $(printf '%s' "$2" | head -c 200)" ;;
  esac
}
assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1" "unexpected needle '$3' in: $(printf '%s' "$2" | head -c 200)" ;;
    *)      ok "$1" ;;
  esac
}
assert_exists() { [ -e "$2" ] && ok "$1" || fail "$1" "missing: $2"; }
assert_absent() { [ ! -e "$2" ] && ok "$1" || fail "$1" "unexpected: $2"; }
assert_is_dir()     { [ -d "$2" ] && ok "$1" || fail "$1" "not a dir: $2"; }
assert_is_symlink() { [ -L "$2" ] && ok "$1" || fail "$1" "not a symlink: $2"; }
assert_is_file()    { [ -f "$2" ] && ok "$1" || fail "$1" "not a regular file: $2"; }

# run_capture <stdin> <args...>  — runs stax with given stdin string and args,
# captures stdout, stderr, and exit code into RUN_OUT / RUN_ERR / RUN_RC.
run_capture() {
  local stdin="$1"; shift
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  if [ -n "$stdin" ]; then
    printf '%s' "$stdin" | "$BUILD_BIN" "$@" >"$out_file" 2>"$err_file"
  else
    "$BUILD_BIN" "$@" >"$out_file" 2>"$err_file" </dev/null
  fi
  RUN_RC=$?
  RUN_OUT="$(cat "$out_file")"
  RUN_ERR="$(cat "$err_file")"
  rm -f "$out_file" "$err_file"
}

# fresh_project — creates an isolated project directory and echoes its path.
# Callers MUST `cd "$dir"` themselves; doing the cd inside this function is
# useless because `$(...)` captures stdout in a subshell whose cwd dies with it.
fresh_project() {
  mktemp -d "$PROJECTS_ROOT/proj.XXXXXX"
}

# ---------- background-server helpers ----------
#
# Bare `stax` now starts a loopback HTTP server on 127.0.0.1:7829 and
# blocks on SIGINT/SIGTERM. Tests that exercise the server need to:
#   1. Spawn the binary in the background.
#   2. Wait for the port to start listening.
#   3. Curl the API endpoints.
#   4. SIGTERM the process and reap it.
#
# bg_spawn_stax / bg_kill_stax wrap the spawn + reap, BG_PID carries the
# pid between the two. Output is tee'd into BG_STDOUT / BG_STDERR for
# post-mortem assertions on the server's stdout/stderr lines (e.g. the
# "listening on …" banner).

# bg_spawn_stax <args...>
# Starts stax in the background with the given args, waits up to 5s for
# the port to start listening, then returns. Sets BG_PID (process id),
# BG_STDOUT (path to captured stdout), BG_STDERR (path to captured
# stderr). The caller MUST eventually call bg_kill_stax.
bg_spawn_stax() {
  BG_STDOUT="$(mktemp)"
  BG_STDERR="$(mktemp)"
  BG_URL=""
  "$BUILD_BIN" "$@" >"$BG_STDOUT" 2>"$BG_STDERR" </dev/null &
  BG_PID=$!
  # Poll up to 5s for OUR spawn's listening banner to appear in
  # BG_STDOUT. Trusting "curl succeeded" alone would be unsafe: if a
  # stray stax server (or some other process) is already squatting on
  # the port, OUR spawn either exits with EADDRINUSE or falls through
  # to an adjacent port (per serverPortFallbackAttempts) — curl against
  # the hard-coded preferred URL would talk to the squatter, not us.
  # Extracting the URL from the banner ("Stax server listening on
  # <URL>") is the unforgeable signal that our process actually bound
  # AND the right host:port to probe. Cross-checked with a zombie-aware
  # liveness probe (kill -0 returns success for an unreaped child until
  # wait() runs).
  local i stat extracted_url
  for i in $(seq 1 50); do
    extracted_url="$(grep -oE 'Stax server listening on [^[:space:]]+' "$BG_STDOUT" 2>/dev/null | head -1 | awk '{print $NF}')"
    if [ -n "$extracted_url" ]; then
      BG_URL="$extracted_url"
      if curl -fsS --max-time 1 "${BG_URL}${STAX_API_STATS_PATH}" >/dev/null 2>&1; then
        return 0
      fi
    fi
    if ! kill -0 "$BG_PID" 2>/dev/null; then
      printf 'stax background process died before listening\n' >&2
      printf '  stdout: %s\n' "$(cat "$BG_STDOUT")" >&2
      printf '  stderr: %s\n' "$(cat "$BG_STDERR")" >&2
      wait "$BG_PID" 2>/dev/null
      return 1
    fi
    # Zombie detection: ps prints 'Z' (or 'Z+') in the STAT column for
    # an exited-but-unreaped child. Without this, a child that died on
    # bind would keep us looping until the 5s timeout.
    stat="$(ps -p "$BG_PID" -o stat= 2>/dev/null | tr -d ' ')"
    if [ "${stat#Z}" != "$stat" ]; then
      printf 'stax background process exited (zombie) before listening\n' >&2
      printf '  stdout: %s\n' "$(cat "$BG_STDOUT")" >&2
      printf '  stderr: %s\n' "$(cat "$BG_STDERR")" >&2
      wait "$BG_PID" 2>/dev/null
      return 1
    fi
    sleep 0.1
  done
  printf 'stax server never printed a listening banner\n' >&2
  printf '  stdout: %s\n' "$(cat "$BG_STDOUT")" >&2
  printf '  stderr: %s\n' "$(cat "$BG_STDERR")" >&2
  kill "$BG_PID" 2>/dev/null
  wait "$BG_PID" 2>/dev/null
  return 1
}

# bg_kill_stax — sends SIGTERM to the backgrounded stax, waits for it to
# reap, and clears BG_PID / BG_STDOUT / BG_STDERR. Safe to call when no
# server was spawned (no-op).
bg_kill_stax() {
  if [ -n "${BG_PID:-}" ]; then
    kill "$BG_PID" 2>/dev/null
    wait "$BG_PID" 2>/dev/null
    BG_PID=""
  fi
  if [ -n "${BG_STDOUT:-}" ]; then
    rm -f "$BG_STDOUT"
    BG_STDOUT=""
  fi
  if [ -n "${BG_STDERR:-}" ]; then
    rm -f "$BG_STDERR"
    BG_STDERR=""
  fi
}

# Make sure any leftover server process from a failing case is reaped on
# exit. Layered on top of the existing sandbox cleanup trap.
trap 'bg_kill_stax 2>/dev/null; chmod -R +w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX" 2>/dev/null' EXIT

# reset_user_home — wipe the configured-agent dirs and ~/${STAX_DIR}
# between cases so the next case starts from a known state. Uses the
# constants block so adding a new agentTarget only requires updating that
# block.
reset_user_home() {
  rm -rf "$HOME/${CLAUDE_CONFIG_REL}" \
         "$HOME/${CODEX_CONFIG_REL}" \
         "$HOME/${CODEX_SKILLS_PARENT}" \
         "$HOME/${OPENCODE_SKILLS_PARENT}" \
         "$HOME/${CLINE_SKILLS_PARENT}" \
         "$HOME/${CONTINUE_SKILLS_PARENT}" \
         "$HOME/${CURSOR_USER_SKILLS_PARENT}" \
         "$HOME/${KILO_SKILLS_PARENT}" \
         "$HOME/${COPILOT_USER_CONFIG_PARENT}" \
         "$HOME/${OPENCODE_USER_CONFIG_PARENT}" \
         "$HOME/${PI_USER_CONFIG_PARENT}" \
         "$HOME/${ANTIGRAVITY_USER_HOME_PARENT}" \
         "$HOME/${STAX_DIR}"
}

# seed_project_scaffold <dir> — creates the minimal "fully initialized stax
# project" structure that `checkProject` requires: the planDir directory plus
# the two scaffold files (`_data_systems.yaml`, `_config.lock`) that
# `stax init` would write. Used by every `work-items *` / `skill remove --project`
# case that exercises the project-marker check's happy path without running
# `stax init` itself. The two files are zero-byte placeholders — exactly what
# an empty fresh project looks like — so individual cases can overwrite
# them with case-specific content (e.g. a custom prefix_width lock).
seed_project_scaffold() {
  mkdir -p "$1/${STAX_DIR}"
  : > "$1/${STAX_DIR}/${STAX_SYSTEMS_FILE}"
  : > "$1/${STAX_DIR}/${STAX_LOCK_FILE}"
}

# prefix <width> <n> — render n as a zero-padded prefix of the given width.
# Mirrors the binary's `fmt.Printf("%0*d\n", width, n)`.
prefix() { printf "%0${1}d" "$2"; }

# sha256_of <path> — print the SHA-256 hex digest of the file at <path>,
# resolving through symlinks (so user-scope installs that link into
# ~/.stax/agents/ still produce the digest of the linked-to bytes).
# Portable across Linux (`sha256sum`) and macOS (`shasum -a 256`).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# write_work_item <dir> <name> <status> <inline-systems> — helper used by the
# `work-items list` cases to seed a frontmatter-having work-item file.
write_work_item() {
  local p="$1/$2"
  cat > "$p" <<EOF
---
status: $3
systems: [$4]
---
## Goal
body
EOF
}

# write_work_item_body <dir> <name> <body> — seeds a work item whose body is exactly
# <body>. Used by the overflow-keywords cases that need predictable body
# content for regex matching. The `systems:` array carries a kebab id so
# the work item is round-trippable through `--system auth`.
write_work_item_body() {
  local p="$1/$2" body="$3"
  cat > "$p" <<EOF
---
status: valid
systems: [auth]
---
${body}
EOF
}

# seed_many_plans <dir> <count> <body-template>
# Seeds <count> work items with predictable slugs (NNNNN-work-itemNNN) and bodies
# formatted as "<body-template> N". Body-template may carry shell-safe
# substitution markers like '%KEY%' if the caller post-processes them.
seed_many_plans() {
  local dir="$1" count="$2" body_template="$3"
  local i name pad
  for (( i=1; i<=count; i++ )); do
    pad="$(printf '%03d' "$i")"
    name="$(prefix "$DEFAULT_PREFIX_WIDTH" "$i")-work-item${pad}.md"
    write_work_item_body "$dir" "$name" "${body_template} ${i}"
  done
}

# write_full_work_item <dir> <name> <status> <inline-system-ids> <ears-subject-name> —
# seeds a work item that passes every lint check by default (frontmatter,
# required sections, EARS subject name resolving to the declared system id
# via the registry). Used by the `work-items lint` cases as the baseline;
# individual cases override one field to trip a single finding. The 4th
# arg goes into `systems:` (kebab ids); the 5th arg goes into the EARS
# subject (display name). They are two coordinates of the same registry
# entry — the linter resolves the subject name to its id and checks the
# id set against the declared ids.
#
# The title is derived from the filename slug so the title↔filename lint
# stays satisfied; cases that intentionally break the filename also fail
# lintFilename, which short-circuits the title↔filename check.
write_full_work_item() {
  local p="$1/$2"
  local slug="${2#*-}"
  slug="${slug%.md}"
  : "${slug:=foo}"
  cat > "$p" <<EOF
---
title: $slug
status: $3
systems: [$4]
created: 2026-05-23T14:30:00Z
---

## Goal
Do a thing.

## Approach
- A

## Tasks
- [ ] The $5 shall do a thing.
EOF
}

# write_registry <dir> <name>[,<name>...] — seeds .stax/_data_systems.yaml
# with one entry per comma-separated name, slug derived from the name.
write_registry() {
  local p="$1/${STAX_SYSTEMS_FILE}"
  {
    printf 'systems:\n'
    local IFS=,
    for name in $2; do
      name="${name# }"; name="${name% }"
      printf '  - id: %s\n    name: %s\n    brief: test system\n' \
        "$(printf '%s' "$name" | tr '[:upper:] ' '[:lower:]-')" "$name"
    done
  } > "$p"
}

# ---------- build ----------

# server.go embeds `frontend/dist/` via `//go:embed all:frontend/dist`. The
# dist tree is gitignored, so a fresh clone (or any pre-push hook running
# against an un-built frontend) has nothing for the embed to match and
# `go build` fails with "pattern all:frontend/dist: no matching files".
# CI builds dist in a separate workflow step (.github/workflows/test.yml),
# but the lefthook pre-push hook calls this script directly — so we
# bootstrap dist here when it's missing. Already-built trees are left
# untouched to keep local re-runs fast; pass FORCE_FRONTEND_BUILD=1 to
# rebuild unconditionally.
case_start "build frontend (for //go:embed all:frontend/dist)"
if [ "${FORCE_FRONTEND_BUILD:-}" = "1" ] || [ ! -d "$REPO_ROOT/frontend/dist" ]; then
  (
    cd "$REPO_ROOT/frontend"
    # `npm ci` is skipped when node_modules already exists — it would
    # otherwise wipe and reinstall on every run, which is multi-second
    # overhead the dev cycle does not need.
    if [ ! -d node_modules ]; then
      npm ci
    fi
    npm run build
  )
  assert_is_dir "frontend/dist built" "$REPO_ROOT/frontend/dist"
else
  ok "frontend/dist already present (skipping build; set FORCE_FRONTEND_BUILD=1 to override)"
fi

case_start "build stax"
(
  cd "$REPO_ROOT"
  # -ldflags stamps a recognizable version so installer-format assertions
  # can verify the last whitespace token on line 1 of --version.
  #
  # -buildvcs=false disables Go's automatic embedding of VCS metadata into
  # the binary. The e2e binary is an ephemeral throwaway built inside the
  # sandbox; VCS provenance is only meaningful for release artifacts (the
  # release.yml workflow keeps stamping intact). Disabling it here also
  # immunizes the test against the "dubious ownership" failure mode that
  # bites when the workflow's mounted workspace user-id differs from the
  # container's runtime user — go build → git status → fatal → exit 128.
  go build -buildvcs=false \
    -ldflags "-X main.Version=${E2E_VERSION}" \
    -o "$BUILD_BIN" .
)
assert_exists "binary built" "$BUILD_BIN"
[ -x "$BUILD_BIN" ] && ok "binary is executable" || fail "binary is executable"

# Now that the build is done, switch HOME to the sandbox for every CLI
# invocation. Doing this AFTER the build keeps Go's module cache in the
# developer's real $HOME instead of repopulating one inside the sandbox.
export HOME="$SANDBOX_HOME"
export USERPROFILE="$HOME"   # noop on POSIX, matters on Windows.

# ---------- post-install (installer hook: silent seed) ----------
#
# install.sh's last step invokes `stax post-install` to materialize
# ~/.stax/agents/ from the binary's embed. The contract: silent on
# stdout/stderr, exit 0, and the lazy-bootstrap of the agents tree
# happens before exit. Bare `stax` is now reserved for the local-server
# behavior and would block on the listener mid-install — `post-install`
# is the replacement entry point.

case_start "stax post-install seeds agents silently"
reset_user_home
run_capture "" post-install
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "no stdout" "$RUN_OUT" ""
assert_eq "no stderr" "$RUN_ERR" ""
assert_is_dir "lazy-bootstrap agents dir" "$HOME/${STAX_AGENTS_DIR}"
assert_is_dir "lazy-bootstrap skill ${SKILL_SHIP_DIR}" \
  "$HOME/${STAX_AGENTS_SKILLS_DIR}/${SKILL_SHIP_DIR}"

# ---------- bare stax launches the loopback API server ----------
#
# Bare `stax` starts the loopback HTTP server on
# ${STAX_SERVER_DISPLAY_URL} and blocks on SIGINT/SIGTERM. Spawn it in
# the background, probe /api/stats + /api/systems, then SIGTERM the
# process. --no-browser is the opt-out for the auto browser launch (the
# server still starts); we use it here so the spawn cannot pop a window
# on a dev workstation.

case_start "stax --no-browser starts the loopback API server"
reset_user_home
PROJ_NOBROWSER="$(fresh_project)"
seed_project_scaffold "$PROJ_NOBROWSER"
bg_spawn_stax --no-browser --cwd "$PROJ_NOBROWSER"
assert_eq "spawn succeeded" "$?" "0"
# Curl the URL the spawn actually bound (BG_URL is exported by
# bg_spawn_stax after extracting it from the listening banner) — the
# preferred port may have been busy and the server fell forward to an
# adjacent one. /api/stats carries the running version + system/scope
# totals; the liveness probe bg_spawn_stax already waited on
# succeeded, so a redundant curl here lets us assert on body shape.
stats_body="$(curl -fsS --max-time 1 "${BG_URL}${STAX_API_STATS_PATH}")"
assert_contains "stats version" "$stats_body" "\"version\":\"${E2E_VERSION}\""
assert_contains "stats systems" "$stats_body" '"systems":'
assert_contains "stats workItems"  "$stats_body" '"workItems":'
# stdout carries the listening banner — pin both the URL and the
# Ctrl-C hint so a reshuffle of runServer's banner shows up here.
listening_banner="$(cat "$BG_STDOUT")"
assert_contains "listening banner"   "$listening_banner" "$BG_URL"
assert_contains "ctrl-c hint"        "$listening_banner" "Ctrl-C"
# --no-browser suppresses the browser handoff. No browser-error noise
# should hit stderr (the warning only fires when openBrowser is called
# and fails); pin "no browser warning" so a future flip of the gate
# is loud.
err_text="$(cat "$BG_STDERR")"
assert_not_contains "no browser warning" "$err_text" "could not open browser"
bg_kill_stax
# Lazy-bootstrap of the bundled agents tree still happens before the
# server starts — the user typing `stax` for the first time gets the
# embed materialized on disk same as any subcommand would do.
assert_is_dir "lazy-bootstrap agents dir" "$HOME/${STAX_AGENTS_DIR}"

# ---------- bare stax in a non-project directory ----------
#
# Bare `stax` (and `stax --no-browser`) only makes sense inside an
# initialized project — the UI's /api/work-items, /api/work-item, and the
# detail mode of /api/systems all read from .stax/. Surface the
# canonical `stax init` banner to stderr, exit 2 (usage error),
# and DO NOT bind the listener or open a browser.

case_start "stax --cwd <not-a-project> prints init banner and exits 2"
reset_user_home
NOPROJ_BARE="$(fresh_project)"
run_capture "" --no-browser --cwd "$NOPROJ_BARE"
assert_eq "exit 2"     "$RUN_RC"  "2"
assert_eq "no stdout"  "$RUN_OUT" ""
assert_contains "init-banner stderr" "$RUN_ERR" "not a stax project"
assert_contains "init-banner stderr" "$RUN_ERR" "stax init"

# ---------- /api/systems with --cwd PATH ----------
#
# /api/systems reads .stax/_data_systems.yaml from the running stax's
# cwd. --cwd is the documented knob for pointing the server at a sibling
# project without an explicit cd. Seed a registry under PROJ, spawn the
# server with --cwd PROJ, and assert the JSON carries the seeded entry.

case_start "stax --cwd <PROJ> serves /api/systems for that project"
reset_user_home
PROJ_API="$(fresh_project)"
seed_project_scaffold "$PROJ_API"
printf 'systems:\n  - id: auth\n    name: Auth Service\n' \
  > "$PROJ_API/${STAX_DIR}/${STAX_SYSTEMS_FILE}"
bg_spawn_stax --no-browser --cwd "$PROJ_API"
assert_eq "spawn succeeded" "$?" "0"
systems_body="$(curl -fsS --max-time 1 "${BG_URL}${STAX_API_SYSTEMS_PATH}")"
assert_contains "systems id"   "$systems_body" '"id":"auth"'
assert_contains "systems name" "$systems_body" '"name":"Auth Service"'
bg_kill_stax

# ---------- /api/systems on an initialized but empty project ----------
#
# A directory with .stax/_config.lock (so it crosses the project gate)
# but no _data_systems.yaml is a normal state — `stax init` writes a
# zero-byte placeholder for the registry. /api/systems MUST answer
# 200 with an empty array so a UI can render a friendly empty state
# rather than an error toast.

case_start "stax --cwd <empty-project> serves /api/systems as empty list"
reset_user_home
EMPTY_PROJ="$(fresh_project)"
seed_project_scaffold "$EMPTY_PROJ"
rm -f "$EMPTY_PROJ/${STAX_DIR}/${STAX_SYSTEMS_FILE}"
bg_spawn_stax --no-browser --cwd "$EMPTY_PROJ"
assert_eq "spawn succeeded" "$?" "0"
systems_body="$(curl -fsS --max-time 1 "${BG_URL}${STAX_API_SYSTEMS_PATH}")"
assert_contains "empty systems list" "$systems_body" '"systems":[]'
bg_kill_stax

# ---------- /api/systems?id=<known> detail mode with work items ----------
#
# Detail mode returns the named system plus every work item whose frontmatter
# `systems:` array contains the id, with each work item's markdown body
# pre-rendered to HTML server-side. Seed a project with one matching
# work item and assert the response carries id/name/title/status and rendered
# HTML — anything looser would let a regression in the markdown step
# pass silently.

case_start "stax /api/systems?id=<known> returns detail with rendered HTML"
reset_user_home
PROJ_DETAIL="$(fresh_project)"
seed_project_scaffold "$PROJ_DETAIL"
printf 'systems:\n  - id: auth\n    name: Auth Service\n' \
  > "$PROJ_DETAIL/${STAX_DIR}/${STAX_SYSTEMS_FILE}"
write_full_work_item "$PROJ_DETAIL/${STAX_DIR}" "0001-add-pkce.md" "valid" "auth" "Auth Service"
bg_spawn_stax --no-browser --cwd "$PROJ_DETAIL"
assert_eq "spawn succeeded" "$?" "0"
detail_body="$(curl -fsS --max-time 1 "${BG_URL}${STAX_API_SYSTEMS_PATH}?id=auth")"
assert_contains "detail id"     "$detail_body" '"id":"auth"'
assert_contains "detail name"   "$detail_body" '"name":"Auth Service"'
assert_contains "detail slug"    "$detail_body" '"slug":"0001-add-pkce"'
assert_contains "detail status"  "$detail_body" '"status":"valid"'
assert_contains "detail created" "$detail_body" '"created":"2026-05-23T14:30:00Z"'
bg_kill_stax

# ---------- /api/systems?id=<unknown> returns 404 ----------
#
# An id that is not declared in the registry must surface as a 404 with
# a JSON error body so the UI can distinguish "system does not exist"
# from "system exists but has no work items yet" (which is a 200 with empty
# work items). curl --fail-with-body keeps the body even on non-2xx so we can
# assert on the error message.

case_start "stax /api/systems?id=<unknown> returns 404"
reset_user_home
PROJ_404="$(fresh_project)"
seed_project_scaffold "$PROJ_404"
printf 'systems:\n  - id: auth\n    name: Auth Service\n' \
  > "$PROJ_404/${STAX_DIR}/${STAX_SYSTEMS_FILE}"
bg_spawn_stax --no-browser --cwd "$PROJ_404"
assert_eq "spawn succeeded" "$?" "0"
http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 1 "${BG_URL}${STAX_API_SYSTEMS_PATH}?id=nope")"
assert_eq "404 status" "$http_code" "404"
not_found_body="$(curl -sS --max-time 1 "${BG_URL}${STAX_API_SYSTEMS_PATH}?id=nope")"
assert_contains "error field" "$not_found_body" '"error"'
bg_kill_stax

# ---------- --version (still prints notice for installer parsing) ----------
#
# install.sh's version-detection awk parses `stax --version` line 1 to
# seed ~/.stax/.config.json. Bare `stax` no longer prints the notice
# (it opens a browser), so this is now the canonical version-printing
# entry point. The first-line-last-token assertion pins the awk
# contract.

case_start "stax --version prints notice and bootstraps agents"
reset_user_home
run_capture "" --version
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "version line" "$RUN_OUT" "Stax by Stackific, ${E2E_VERSION}"
assert_contains "copyright"    "$RUN_OUT" "Copyright 2026 Stackific Inc."
assert_contains "spdx"         "$RUN_OUT" "SPDX-License-Identifier: Apache-2.0"
assert_not_contains "no usage block" "$RUN_OUT" "Usage:"
first_line_last_token="$(printf '%s' "$RUN_OUT" | awk 'NR==1 { print $NF; exit }')"
assert_eq "first-line last token is version" "$first_line_last_token" "${E2E_VERSION}"
assert_is_dir "lazy-bootstrap agents dir" "$HOME/${STAX_AGENTS_DIR}"
assert_is_dir "lazy-bootstrap skill ${SKILL_SHIP_DIR}" \
  "$HOME/${STAX_AGENTS_SKILLS_DIR}/${SKILL_SHIP_DIR}"

# ---------- -h / --help ----------

case_start "stax -h prints notice + usage"
reset_user_home
run_capture "" -h
assert_eq "exit 0" "$RUN_RC" "0"
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "usage header"        "$combined" "Usage:"
assert_contains "no-browser listed"   "$combined" "--no-browser"
assert_contains "post-install listed" "$combined" "stax post-install"
assert_contains "init listed"         "$combined" "stax init"
assert_not_contains "no bootstrap"    "$combined" "stax bootstrap"
assert_contains "skill remove user"   "$combined" "stax skills remove --user"
assert_contains "skill remove proj"   "$combined" "stax skills remove --project"
assert_contains "work-items next-prefix"    "$combined" "stax work-items next-prefix"
assert_contains "work-items list"           "$combined" "stax work-items list"
assert_contains "work-items lint"           "$combined" "stax work-items lint"
assert_contains "work-items slugify"        "$combined" "stax work-items slugify"
assert_contains "version listed"      "$combined" "stax --version"
assert_contains "cwd flag listed"     "$combined" "--cwd <path>"
# Help text MUST NOT leak server internals — the HTTP routes and the
# listen URL are implementation details behind the web UI, not user
# surfaces.
assert_not_contains "no api stats leak"   "$combined" "$STAX_API_STATS_PATH"
assert_not_contains "no api systems leak" "$combined" "$STAX_API_SYSTEMS_PATH"
assert_not_contains "no listen url leak"  "$combined" "$STAX_SERVER_DISPLAY_URL"

# ---------- bootstrap is no longer a callable subcommand ----------

case_start "stax bootstrap exits 2 (no longer a subcommand)"
reset_user_home
run_capture "" bootstrap
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "unknown subcommand: bootstrap"

# ---------- unknown subcommand ----------

case_start "stax typo exits with code 2"
run_capture "" doesnotexist
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic on stderr" "$RUN_ERR" "unknown subcommand: doesnotexist"

# ---------- init --scope project ----------

case_start "stax init --scope project end-to-end"
reset_user_home
PROJ="$(fresh_project)"
cd "$PROJ"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "progress line" "$RUN_OUT" "Setting up stax in $PROJ"
assert_contains "completion"    "$RUN_OUT" "Done."
assert_contains "git-commit tip" "$RUN_OUT" "commit ${STAX_DIR}/ to git"
for base in "${CLAUDE_SKILLS_REL}" "${CODEX_SKILLS_REL}"; do
  for skill in $OWNED_SKILLS; do
    assert_is_dir "project $base/$skill" "$PROJ/$base/$skill"
  done
done
assert_is_file "project ${CLAUDE_SETTINGS_PATH}" "$PROJ/${CLAUDE_SETTINGS_PATH}"
assert_is_file "project ${CODEX_HOOKS_PATH}"     "$PROJ/${CODEX_HOOKS_PATH}"
assert_is_file "${STAX_LOCK_PATH} written"       "$PROJ/${STAX_LOCK_PATH}"
assert_is_file "${STAX_SYSTEMS_PATH} written"    "$PROJ/${STAX_SYSTEMS_PATH}"
assert_contains "${STAX_LOCK_PATH} has prefix_width" \
  "$(cat "$PROJ/${STAX_LOCK_PATH}")" "\"prefix_width\": ${DEFAULT_PREFIX_WIDTH}"
assert_contains "${STAX_LOCK_PATH} has review_per" \
  "$(cat "$PROJ/${STAX_LOCK_PATH}")" "\"review_per\": \"task\""
assert_absent "${AGENTS_EMBED_ROOT}/${EMBED_README} not materialized" \
  "$HOME/${STAX_AGENTS_DIR}/${EMBED_README}"

# ---------- init --scope user ----------

case_start "stax init --scope user end-to-end"
reset_user_home
USER_INIT_CWD="$(fresh_project)"
cd "$USER_INIT_CWD"
run_capture "" init --scope user
assert_eq "exit 0" "$RUN_RC" "0"
for base in "${CLAUDE_SKILLS_REL}" "${CODEX_SKILLS_REL}"; do
  for skill in $OWNED_SKILLS; do
    assert_is_symlink "user $base/$skill is symlink" "$HOME/$base/$skill"
    target="$(readlink "$HOME/$base/$skill")"
    case "$target" in
      "$HOME/${STAX_AGENTS_SKILLS_DIR}/$skill")
        ok "user $base/$skill points to agentsTarget" ;;
      *)
        fail "user $base/$skill points to agentsTarget" "got=$target" ;;
    esac
  done
done
# User-scope MUST also drop the ${STAX_DIR}/ scaffold into cwd. Scope
# only decides where SKILLS land (project tree vs \$HOME); the project
# marker check keyed on <cwd>/${STAX_LOCK_PATH} is what makes cwd usable
# with `/scope`, `/ship`, and the `stax work-items *` CLI subcommands.
assert_is_file "user-scope seeds ${STAX_LOCK_PATH} in cwd" \
  "${USER_INIT_CWD}/${STAX_LOCK_PATH}"
assert_is_file "user-scope seeds ${STAX_SYSTEMS_PATH} in cwd" \
  "${USER_INIT_CWD}/${STAX_SYSTEMS_PATH}"

# ---------- init interactive prompts ----------
#
# init now has FIVE interactive questions: agents → scope → prefix-width
# → max-work-item-lines → work-item-review-per. Each pipe below answers them in
# that order; blank lines accept the prompt's default (all agents for
# the multi-select, the project default for the three work-item-tooling
# prompts). promptScope is the only one with NO blank-default: it must
# receive a literal "1" or "2".
#
# In a real terminal, runInit drives a charmbracelet/huh wizard instead
# of these line prompts (with arrow-key select, multiselect, and
# Shift+Tab back-nav). Piped stdin is not a TTY, so this CI path always
# exercises the line-prompt branch — see resolveInitConfig in init.go.
#
# Per AGENTS.md rule 9, every prompt also has a flag twin — covered in
# the `init flag forms` block further down.

case_start "stax init interactive (default agents + project scope)"
reset_user_home
PROJ_INT="$(fresh_project)"
cd "$PROJ_INT"
# agents=default, scope=project, prefix-width=default, max-lines=default, review=default.
run_capture "
1



" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir  "interactive project skill" "$PROJ_INT/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_file "interactive work-item lock"     "$PROJ_INT/${STAX_LOCK_PATH}"
assert_contains "interactive lock keeps default prefix_width" \
  "$(cat "$PROJ_INT/${STAX_LOCK_PATH}")" "\"prefix_width\": ${DEFAULT_PREFIX_WIDTH}"

case_start "stax init interactive (default agents + user scope)"
reset_user_home
cd "$(fresh_project)"
run_capture "
2



" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_exists "interactive user skill" "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"

case_start "stax init interactive (explicit agents + project scope)"
reset_user_home
PROJ_INT2="$(fresh_project)"
cd "$PROJ_INT2"
# Picker indices follow agentTargets order (alphabetical by display
# name): 1 = Claude Code, 2 = Cline, 3 = Codex CLI, … Pick 1+3 so the
# install lands BOTH a `.claude/skills/` tree (CLAUDE_SKILLS_REL) AND a
# `.agents/skills/` tree (CODEX_SKILLS_REL), proving the multi-select
# loop preserves order and the two agents' distinct destinations.
run_capture "1,3
1



" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "interactive explicit agents installs claude" "$PROJ_INT2/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_dir "interactive explicit agents installs codex"  "$PROJ_INT2/${CODEX_SKILLS_REL}/${SKILL_SHIP_DIR}"

case_start "stax init interactive (custom prefix-width + max-work-item-lines + review)"
reset_user_home
PROJ_INT3="$(fresh_project)"
cd "$PROJ_INT3"
# agents=default, scope=project, prefix=6, max=42, review=2 (work-item).
run_capture "
1
6
42
2
" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "interactive lock honors custom prefix_width" \
  "$(cat "$PROJ_INT3/${STAX_LOCK_PATH}")" "\"prefix_width\": 6"
assert_contains "interactive lock honors custom max_work_item_lines" \
  "$(cat "$PROJ_INT3/${STAX_LOCK_PATH}")" "\"max_work_item_lines\": 42"
assert_contains "interactive lock honors custom review_per" \
  "$(cat "$PROJ_INT3/${STAX_LOCK_PATH}")" "\"review_per\": \"work-item\""

case_start "stax init interactive (invalid agent choice)"
reset_user_home
cd "$(fresh_project)"
# Pick "99" — comfortably beyond any realistic agentTargets size, so
# the input is guaranteed out-of-range without having to track the
# exact count as new agents are added.
run_capture "99
" init
[ "$RUN_RC" != "0" ] && ok "non-zero exit on invalid agent choice" || fail "non-zero exit on invalid agent choice"
assert_contains "diagnostic on stderr" "$RUN_ERR" "invalid agent choice"

case_start "stax init interactive (invalid scope choice)"
reset_user_home
cd "$(fresh_project)"
run_capture "
9
" init
[ "$RUN_RC" != "0" ] && ok "non-zero exit on invalid scope choice" || fail "non-zero exit on invalid scope choice"
assert_contains "diagnostic on stderr" "$RUN_ERR" "invalid"

case_start "stax init interactive (invalid prefix-width)"
reset_user_home
cd "$(fresh_project)"
# agents=default, scope=project, prefix=bogus.
run_capture "
1
xyz
" init
[ "$RUN_RC" != "0" ] && ok "non-zero exit on bogus prefix-width" || fail "non-zero exit on bogus prefix-width"
assert_contains "diagnostic on stderr" "$RUN_ERR" "invalid prefix-width"

# ---------- init --agents / --scope flag forms (non-interactive twins) ----------

case_start "stax init --agents=claude installs only Claude Code"
reset_user_home
PROJ_AC="$(fresh_project)"
cd "$PROJ_AC"
run_capture "" init --agents=claude --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "claude installed" "$PROJ_AC/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "codex NOT installed" "$PROJ_AC/${CODEX_SKILLS_REL}"

case_start "stax init --agents=codex installs only Codex CLI"
reset_user_home
PROJ_AX="$(fresh_project)"
cd "$PROJ_AX"
run_capture "" init --agents=codex --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "codex installed" "$PROJ_AX/${CODEX_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude NOT installed" "$PROJ_AX/${CLAUDE_SKILLS_REL}"

case_start "stax init --agents=claude,codex (both)"
reset_user_home
PROJ_AB="$(fresh_project)"
cd "$PROJ_AB"
run_capture "" init --agents=claude,codex --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "claude installed" "$PROJ_AB/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_dir "codex installed"  "$PROJ_AB/${CODEX_SKILLS_REL}/${SKILL_SHIP_DIR}"

case_start "stax init --agents=opencode installs only OpenCode"
reset_user_home
PROJ_AO="$(fresh_project)"
cd "$PROJ_AO"
run_capture "" init --agents=opencode --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "opencode installed" "$PROJ_AO/${OPENCODE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude NOT installed" "$PROJ_AO/${CLAUDE_SKILLS_REL}"
assert_absent "codex NOT installed"  "$PROJ_AO/${CODEX_SKILLS_REL}"

case_start "stax init --agents=claude,codex,opencode (all three)"
reset_user_home
PROJ_AT="$(fresh_project)"
cd "$PROJ_AT"
run_capture "" init --agents=claude,codex,opencode --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "claude installed"   "$PROJ_AT/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_dir "codex installed"    "$PROJ_AT/${CODEX_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_dir "opencode installed" "$PROJ_AT/${OPENCODE_SKILLS_REL}/${SKILL_SHIP_DIR}"

case_start "stax init --agents=copilot installs GitHub Copilot CLI at project scope"
reset_user_home
PROJ_CP="$(fresh_project)"
cd "$PROJ_CP"
run_capture "" init --agents=copilot --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
# Copilot's project skillsRel coincides with Codex's `.agents/skills` (cross-
# agent open spec). We still expect the directory + each owned skill present.
assert_is_dir "copilot project skills installed" "$PROJ_CP/${COPILOT_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude NOT installed" "$PROJ_CP/${CLAUDE_SKILLS_REL}"

case_start "stax init --agents=copilot --scope=user lands at ~/.agents/skills"
PROJ_CP_USER="$(fresh_project)"
cd "$PROJ_CP_USER"
reset_user_home
run_capture "" init --agents=copilot --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
# Copilot reuses the Codex `.agents/skills` path at both scopes (cross-
# agent open spec). Skills land under SANDBOX_HOME, project cwd is left
# alone (user scope must not pollute the user's terminal pwd).
assert_is_dir "copilot user-scope skills landed" \
  "${SANDBOX_HOME}/${COPILOT_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "no install under project cwd" \
  "$PROJ_CP_USER/${COPILOT_SKILLS_REL}"

case_start "stax init --agents=pi installs Pi at project scope"
reset_user_home
PROJ_PI="$(fresh_project)"
cd "$PROJ_PI"
run_capture "" init --agents=pi --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
# Pi's project skillsRel coincides with Codex's `.agents/skills` per
# pi-mono's docs/skills.md (cross-agent open spec, walking up from cwd).
# We assert the directory + each owned skill present.
assert_is_dir "pi project skills installed" "$PROJ_PI/${PI_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude NOT installed" "$PROJ_PI/${CLAUDE_SKILLS_REL}"

case_start "stax init --agents=pi --scope=user lands at ~/.agents/skills"
PROJ_PI_USER="$(fresh_project)"
cd "$PROJ_PI_USER"
reset_user_home
run_capture "" init --agents=pi --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
# Pi at user scope reads `~/.agents/skills/` (one of two documented
# global locations per pi-mono/packages/coding-agent/docs/skills.md,
# alongside `~/.pi/agent/skills/`). Skills land under SANDBOX_HOME,
# project cwd is left alone.
assert_is_dir "pi user-scope skills landed" \
  "${SANDBOX_HOME}/${PI_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "no install under project cwd" \
  "$PROJ_PI_USER/${PI_SKILLS_REL}"

case_start "stax init --agents=cline installs Cline at project scope"
reset_user_home
PROJ_CL="$(fresh_project)"
cd "$PROJ_CL"
run_capture "" init --agents=cline --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
# Cline reads project skills from `.cline/skills` (per docs.cline.bot/
# customization/overview). Sibling agent directories must remain absent.
assert_is_dir "cline project skills installed" "$PROJ_CL/${CLINE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude NOT installed" "$PROJ_CL/${CLAUDE_SKILLS_REL}"
assert_absent "codex NOT installed" "$PROJ_CL/${CODEX_SKILLS_REL}"

case_start "stax init --agents=cline --scope=user lands at ~/.cline/skills"
PROJ_CL_USER="$(fresh_project)"
cd "$PROJ_CL_USER"
reset_user_home
run_capture "" init --agents=cline --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
# Cline's user-scope path mirrors its project-scope path under $HOME.
# Skills land under SANDBOX_HOME; project cwd stays clean.
assert_is_dir "cline user-scope skills landed" \
  "${SANDBOX_HOME}/${CLINE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "no install under project cwd" \
  "$PROJ_CL_USER/${CLINE_SKILLS_REL}"

case_start "stax init --agents=omp installs at the shared .agents/skills/ path"
reset_user_home
PROJ_OMP="$(fresh_project)"
cd "$PROJ_OMP"
run_capture "" init --agents=omp --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
# omp reuses the cross-agent `.agents/skills/` path (Codex and Copilot
# do the same — see their cases above). omp's documented `agents`
# skill provider (priority 70 in docs/skills.md) walks the path at
# every cwd ancestor up to repoRoot. The paths the other agents claim
# exclusively (Claude `.claude/skills`, OpenCode `.opencode/commands`)
# must NOT be touched — that's how we know `--agents=omp` didn't
# accidentally install the whole registry.
assert_is_dir "omp project skills installed" \
  "$PROJ_OMP/${OMP_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude path NOT installed"   "$PROJ_OMP/${CLAUDE_SKILLS_REL}"
assert_absent "opencode path NOT installed" "$PROJ_OMP/${OPENCODE_SKILLS_REL}"
# Per-agent config files of OTHER agents (Codex hooks.json, Claude
# settings.json) must also stay absent — confirms the install was
# really scoped to the single requested row, not all of them.
assert_absent "codex config NOT installed"  "$PROJ_OMP/${CODEX_CONFIG_REL}"
assert_absent "claude config NOT installed" "$PROJ_OMP/${CLAUDE_CONFIG_REL}"

case_start "stax init --agents=omp --scope=user lands at ~/.agents/skills"
PROJ_OMP_USER="$(fresh_project)"
cd "$PROJ_OMP_USER"
reset_user_home
run_capture "" init --agents=omp --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
# `agents` provider scans `$HOME/.agents/skills/` at user scope — same
# path Codex and Copilot use at user scope. Skills land under
# SANDBOX_HOME, project cwd is left alone.
assert_is_dir "omp user-scope skills landed" \
  "${SANDBOX_HOME}/${OMP_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "no install under project cwd" \
  "$PROJ_OMP_USER/${OMP_SKILLS_REL}"

case_start "stax init --agents=continue installs at .continue/skills"
reset_user_home
PROJ_CONT="$(fresh_project)"
cd "$PROJ_CONT"
run_capture "" init --agents=continue --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
# Continue scans `.continue/skills/` at project scope (per
# continue.dev customization docs). The cross-agent `.agents/skills`
# is NOT a Continue lookup, so installing there would land files
# Continue never reads.
assert_is_dir "continue project skills installed" \
  "$PROJ_CONT/${CONTINUE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude path NOT installed"   "$PROJ_CONT/${CLAUDE_SKILLS_REL}"
assert_absent "codex path NOT installed"    "$PROJ_CONT/${CODEX_SKILLS_REL}"
assert_absent "cline path NOT installed"    "$PROJ_CONT/${CLINE_SKILLS_REL}"

case_start "stax init --agents=continue --scope=user lands at ~/.continue/skills"
PROJ_CONT_USER="$(fresh_project)"
cd "$PROJ_CONT_USER"
reset_user_home
run_capture "" init --agents=continue --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "continue user-scope skills landed" \
  "${SANDBOX_HOME}/${CONTINUE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "no install under project cwd" \
  "$PROJ_CONT_USER/${CONTINUE_SKILLS_REL}"

case_start "stax init --agents=cursor installs at the shared .agents/skills/ path"
reset_user_home
PROJ_CUR="$(fresh_project)"
cd "$PROJ_CUR"
run_capture "" init --agents=cursor --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
# Cursor at workspace scope uses the cross-agent `.agents/skills`
# path — same as Codex/Copilot/Pi/omp. Cursor's own
# `~/.cursor/skills` is the user-scope-only path.
assert_is_dir "cursor project skills installed" \
  "$PROJ_CUR/${CURSOR_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude path NOT installed" "$PROJ_CUR/${CLAUDE_SKILLS_REL}"
assert_absent "cline path NOT installed"  "$PROJ_CUR/${CLINE_SKILLS_REL}"

case_start "stax init --agents=cursor --scope=user lands at ~/.cursor/skills"
PROJ_CUR_USER="$(fresh_project)"
cd "$PROJ_CUR_USER"
reset_user_home
run_capture "" init --agents=cursor --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
# Cursor diverges at user scope: it reads `~/.cursor/skills/`, NOT
# the cross-agent `~/.agents/skills` fallback. The userSkillsRel
# override drives the install destination, and the cross-agent path
# must stay clean as proof.
assert_is_dir "cursor user-scope skills landed" \
  "${SANDBOX_HOME}/${CURSOR_USER_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "cross-agent ~/.agents/skills NOT touched" \
  "${SANDBOX_HOME}/${CODEX_SKILLS_REL}"
assert_absent "no install under project cwd" \
  "$PROJ_CUR_USER/${CURSOR_USER_SKILLS_REL}"

case_start "stax init --agents=kilo installs at .kilocode/skills"
reset_user_home
PROJ_KILO="$(fresh_project)"
cd "$PROJ_KILO"
run_capture "" init --agents=kilo --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
# Kilo Code (kilocode.ai) reads from `.kilocode/skills/` exclusively.
# Cross-agent `.agents/skills` is NOT a documented Kilo lookup.
assert_is_dir "kilo project skills installed" \
  "$PROJ_KILO/${KILO_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude path NOT installed" "$PROJ_KILO/${CLAUDE_SKILLS_REL}"
assert_absent "codex path NOT installed"  "$PROJ_KILO/${CODEX_SKILLS_REL}"

case_start "stax init --agents=kilo --scope=user lands at ~/.kilocode/skills"
PROJ_KILO_USER="$(fresh_project)"
cd "$PROJ_KILO_USER"
reset_user_home
run_capture "" init --agents=kilo --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "kilo user-scope skills landed" \
  "${SANDBOX_HOME}/${KILO_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "no install under project cwd" \
  "$PROJ_KILO_USER/${KILO_SKILLS_REL}"

case_start "stax init --agents=zed installs at the shared .agents/skills/ path"
reset_user_home
PROJ_ZED="$(fresh_project)"
cd "$PROJ_ZED"
run_capture "" init --agents=zed --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
# Zed honors the cross-agent `.agents/skills` path at BOTH scopes
# (zed.dev "agent panel skills" docs) — install collapses with the
# other cross-agent rows.
assert_is_dir "zed project skills installed" \
  "$PROJ_ZED/${ZED_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "claude path NOT installed" "$PROJ_ZED/${CLAUDE_SKILLS_REL}"
assert_absent "cline path NOT installed"  "$PROJ_ZED/${CLINE_SKILLS_REL}"

case_start "stax init --agents=zed --scope=user lands at ~/.agents/skills"
PROJ_ZED_USER="$(fresh_project)"
cd "$PROJ_ZED_USER"
reset_user_home
run_capture "" init --agents=zed --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "zed user-scope skills landed" \
  "${SANDBOX_HOME}/${ZED_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_absent "no install under project cwd" \
  "$PROJ_ZED_USER/${ZED_SKILLS_REL}"

case_start "stax init --agents=invalid rejects unknown agent"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --agents=workspace --scope=project
assert_eq "exit 1" "$RUN_RC" "1"
assert_contains "diagnostic" "$RUN_ERR" "unknown agent"

# ---------- init --scope invalid ----------

case_start "stax init --scope invalid"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope workspace
assert_eq "exit 1" "$RUN_RC" "1"
assert_contains "diagnostic" "$RUN_ERR" "invalid --scope"

# ---------- init work-item-tooling flag twins (--prefix-width / --max-work-item-lines / --review-per) ----------
#
# All five prompts have flag twins; passing every flag drives runInit
# end-to-end without ever touching stdin (true non-interactive). Each
# case below pins the protocol-format of `_config.lock` so any drift between
# the flag values and what lands on disk fails loud.

case_start "stax init --prefix-width / --max-work-item-lines / --review-per (all flags)"
reset_user_home
PROJ_FF="$(fresh_project)"
cd "$PROJ_FF"
run_capture "" init --scope project --agents=claude,codex \
  --prefix-width=6 --max-work-item-lines=42 --review-per=work-item
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "lock honors --prefix-width" \
  "$(cat "$PROJ_FF/${STAX_LOCK_PATH}")" "\"prefix_width\": 6"
assert_contains "lock honors --max-work-item-lines" \
  "$(cat "$PROJ_FF/${STAX_LOCK_PATH}")" "\"max_work_item_lines\": 42"
assert_contains "lock honors --review-per" \
  "$(cat "$PROJ_FF/${STAX_LOCK_PATH}")" "\"review_per\": \"work-item\""

case_start "stax init --review-per=task (explicit default)"
reset_user_home
PROJ_FT="$(fresh_project)"
cd "$PROJ_FT"
run_capture "" init --scope project --agents=claude --prefix-width=4 \
  --max-work-item-lines=30 --review-per=task
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "lock honors --review-per=task" \
  "$(cat "$PROJ_FT/${STAX_LOCK_PATH}")" "\"review_per\": \"task\""

case_start "stax init --review-per invalid"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project --agents=claude --prefix-width=4 \
  --max-work-item-lines=30 --review-per=commit
assert_eq "exit 1" "$RUN_RC" "1"
assert_contains "diagnostic" "$RUN_ERR" "invalid --review-per"

case_start "stax init --prefix-width=-1 rejected"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project --agents=claude --prefix-width=-1 \
  --max-work-item-lines=30 --review-per=task
assert_eq "exit 1" "$RUN_RC" "1"
assert_contains "diagnostic" "$RUN_ERR" "--prefix-width must be positive"

case_start "stax init --max-work-item-lines=0 rejected"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project --agents=claude --prefix-width=4 \
  --max-work-item-lines=0 --review-per=task
assert_eq "exit 1" "$RUN_RC" "1"
assert_contains "diagnostic" "$RUN_ERR" "--max-work-item-lines must be positive"

case_start "stax init --agents= (empty value) rejected"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project --agents= --prefix-width=4 \
  --max-work-item-lines=30 --review-per=task
assert_eq "exit 1" "$RUN_RC" "1"
assert_contains "diagnostic" "$RUN_ERR" "--agents"

case_start "stax init --review-per= (empty value) rejected"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project --agents=claude --prefix-width=4 \
  --max-work-item-lines=30 --review-per=
assert_eq "exit 1" "$RUN_RC" "1"
assert_contains "diagnostic" "$RUN_ERR" "invalid --review-per"

# ---------- init overwrites prior content at owned skill names ----------

case_start "init clobbers prior content at owned skill names"
reset_user_home
PROJ_OW="$(fresh_project)"
cd "$PROJ_OW"
mkdir -p "$PROJ_OW/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
echo "STALE" > "$PROJ_OW/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}/STALE"
run_capture "" init --scope project
assert_absent "stale file gone after init" "$PROJ_OW/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}/STALE"
assert_is_dir "sibling skill installed"    "$PROJ_OW/${CLAUDE_SKILLS_REL}/${SKILL_SCOPE_DIR}"

# ---------- skill (no subcommand) ----------

case_start "stax skills(no subcommand)"
run_capture "" skills
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: stax skills <subcommand>"

case_start "stax skills <typo>"
run_capture "" skills frobnicate
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "unknown skills subcommand: frobnicate"

# ---------- skill remove (no flag) ----------

case_start "stax skills remove (no flag)"
run_capture "" skills remove
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: stax skills remove"

# ---------- skill remove --user + --project (mutex) ----------

case_start "stax skills remove --user --project (mutex)"
run_capture "" skills remove --user --project
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "mutually exclusive"

# ---------- skill remove --user (end-to-end) ----------

case_start "stax skills remove --user"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope user
mkdir -p "$HOME/${CLAUDE_SKILLS_REL}/my-custom"
touch "$HOME/${CLAUDE_SKILLS_REL}/my-custom/marker"
run_capture "" skills remove --user
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "summary" "$RUN_OUT" "Removed"
for skill in $OWNED_SKILLS; do
  assert_absent "user $skill removed" "$HOME/${CLAUDE_SKILLS_REL}/$skill"
done
assert_is_file "user-authored skill survives" "$HOME/${CLAUDE_SKILLS_REL}/my-custom/marker"

# ---------- skill remove --project (end-to-end) ----------

case_start "stax skills remove --project"
reset_user_home
PROJ_RM="$(fresh_project)"
cd "$PROJ_RM"
run_capture "" init --scope project
mkdir -p "$PROJ_RM/${CLAUDE_SKILLS_REL}/my-custom"
touch "$PROJ_RM/${CLAUDE_SKILLS_REL}/my-custom/marker"
run_capture "" skills remove --project
assert_eq "exit 0" "$RUN_RC" "0"
for skill in $OWNED_SKILLS; do
  assert_absent "project $skill removed" "$PROJ_RM/${CLAUDE_SKILLS_REL}/$skill"
done
assert_is_file "user-authored skill survives"      "$PROJ_RM/${CLAUDE_SKILLS_REL}/my-custom/marker"
assert_is_file "${STAX_LOCK_PATH} preserved"       "$PROJ_RM/${STAX_LOCK_PATH}"
assert_is_file "${CLAUDE_SETTINGS_PATH} preserved" "$PROJ_RM/${CLAUDE_SETTINGS_PATH}"

# ---------- isolation: init must not touch foreign content ----------

case_start "init leaves foreign content under ${CLAUDE_CONFIG_REL}/.agents/${CODEX_CONFIG_REL} alone"
reset_user_home
PROJ_ISO="$(fresh_project)"
cd "$PROJ_ISO"
mkdir -p "$PROJ_ISO/${CLAUDE_CONFIG_REL}/notes" \
         "$PROJ_ISO/${CLAUDE_SKILLS_REL}/my-custom" \
         "$PROJ_ISO/${CODEX_SKILLS_REL}/another-custom" \
         "$PROJ_ISO/${CODEX_CONFIG_REL}/sessions"
echo "USER" > "$PROJ_ISO/${CLAUDE_CONFIG_REL}/CLAUDE.md"
echo "USER" > "$PROJ_ISO/${CLAUDE_CONFIG_REL}/notes/note.txt"
echo "USER" > "$PROJ_ISO/${CLAUDE_SKILLS_REL}/STRAY.md"
echo "USER" > "$PROJ_ISO/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
echo "USER" > "$PROJ_ISO/${CODEX_SKILLS_PARENT}/something.yaml"
echo "USER" > "$PROJ_ISO/${CODEX_SKILLS_REL}/another-custom/SKILL.md"
echo "USER" > "$PROJ_ISO/${CODEX_CONFIG_REL}/config.toml"
echo "USER" > "$PROJ_ISO/${CODEX_CONFIG_REL}/sessions/s1.json"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
for p in \
  "${CLAUDE_CONFIG_REL}/CLAUDE.md" \
  "${CLAUDE_CONFIG_REL}/notes/note.txt" \
  "${CLAUDE_SKILLS_REL}/STRAY.md" \
  "${CLAUDE_SKILLS_REL}/my-custom/SKILL.md" \
  "${CODEX_SKILLS_PARENT}/something.yaml" \
  "${CODEX_SKILLS_REL}/another-custom/SKILL.md" \
  "${CODEX_CONFIG_REL}/config.toml" \
  "${CODEX_CONFIG_REL}/sessions/s1.json"; do
  assert_is_file "preserved $p" "$PROJ_ISO/$p"
  assert_eq      "content $p"   "$(cat "$PROJ_ISO/$p")" "USER"
done
assert_is_dir "bundled ${SKILL_SHIP_DIR} landed"    "$PROJ_ISO/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_dir "bundled ${SKILL_SCOPE_DIR} landed" "$PROJ_ISO/${CODEX_SKILLS_REL}/${SKILL_SCOPE_DIR}"

# ---------- isolation: init re-run merges user-edited JSON config files ----------
#
# `installAgentConfig` deep-merges bundled JSON into a pre-existing
# destination instead of overwriting (the old "skip if exists" behavior)
# OR clobbering it (which would lose user edits). The contract:
#
#   - User-only keys survive.
#   - Bundle-only keys are added (the whole point — a user who already had
#     a settings.json now gets our hooks landed surgically).
#   - The file remains valid JSON after merge.
#   - Work-item-tooling lock file (non-bundled, written by writeWorkItemsScaffold)
#     keeps its lock-file semantics: still skipped, not merged.

case_start "init re-run merges edited ${CLAUDE_SETTINGS_FILE} + ${CODEX_HOOKS_FILE}"
reset_user_home
PROJ_RE="$(fresh_project)"
cd "$PROJ_RE"
run_capture "" init --scope project
# User edits each JSON config to add a custom key. The keys do NOT exist
# in the bundle, so they must survive untouched; the bundled keys
# (fastMode for Claude, hooks for both) must land alongside.
echo '{"USER": "EDIT", "model": "sonnet"}' > "$PROJ_RE/${CLAUDE_SETTINGS_PATH}"
echo '{"USER": "EDIT"}'                    > "$PROJ_RE/${CODEX_HOOKS_PATH}"
# Documented re-init flow: delete the lock to unblock the project-marker
# check's refusal. The lock will be re-written by init from the wizard/flag
# choices for this run.
rm "$PROJ_RE/${STAX_LOCK_PATH}"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
CLAUDE_BODY="$(cat "$PROJ_RE/${CLAUDE_SETTINGS_PATH}")"
CODEX_BODY="$(cat "$PROJ_RE/${CODEX_HOOKS_PATH}")"
assert_contains "${CLAUDE_SETTINGS_FILE} keeps user key"   "$CLAUDE_BODY" '"USER": "EDIT"'
assert_contains "${CLAUDE_SETTINGS_FILE} keeps user model" "$CLAUDE_BODY" '"model": "sonnet"'
assert_contains "${CLAUDE_SETTINGS_FILE} gains fastMode"   "$CLAUDE_BODY" '"fastMode": true'
assert_contains "${CLAUDE_SETTINGS_FILE} gains hook"       "$CLAUDE_BODY" 'stax work-items lint'
assert_contains "${CODEX_HOOKS_FILE} keeps user key"       "$CODEX_BODY"  '"USER": "EDIT"'
assert_contains "${CODEX_HOOKS_FILE} gains hook"           "$CODEX_BODY"  'stax work-items lint'

# ---------- merge is idempotent: a second re-run is a byte-level no-op ----------

case_start "init re-run is idempotent on merged ${CLAUDE_SETTINGS_FILE}"
reset_user_home
PROJ_IDEM_JSON="$(fresh_project)"
cd "$PROJ_IDEM_JSON"
run_capture "" init --scope project
echo '{"model": "sonnet"}' > "$PROJ_IDEM_JSON/${CLAUDE_SETTINGS_PATH}"
echo '{"model": "sonnet"}' > "$PROJ_IDEM_JSON/${CODEX_HOOKS_PATH}"
# First re-run materializes the merged form. Lock-delete is the
# documented project-marker-check bypass; init recreates it from this
# run's choices.
rm "$PROJ_IDEM_JSON/${STAX_LOCK_PATH}"
run_capture "" init --scope project
SNAP_CLAUDE_1="$(cat "$PROJ_IDEM_JSON/${CLAUDE_SETTINGS_PATH}")"
SNAP_CODEX_1="$(cat "$PROJ_IDEM_JSON/${CODEX_HOOKS_PATH}")"
# Second re-run must be a byte-level no-op — array-union dedup catches
# every bundled entry already present from the first merge.
rm "$PROJ_IDEM_JSON/${STAX_LOCK_PATH}"
run_capture "" init --scope project
SNAP_CLAUDE_2="$(cat "$PROJ_IDEM_JSON/${CLAUDE_SETTINGS_PATH}")"
SNAP_CODEX_2="$(cat "$PROJ_IDEM_JSON/${CODEX_HOOKS_PATH}")"
assert_eq "${CLAUDE_SETTINGS_FILE} idempotent" "$SNAP_CLAUDE_1" "$SNAP_CLAUDE_2"
assert_eq "${CODEX_HOOKS_FILE} idempotent"     "$SNAP_CODEX_1"  "$SNAP_CODEX_2"

# ---------- merge: user scalar wins on a conflict ----------
#
# `fastMode: false` is the standard "I opted OUT" choice. A bundled
# `fastMode: true` must NEVER flip the user's explicit `false`. Bundled
# object keys missing from the existing file still land (the `hooks`
# object below) — only the conflicting scalar is left alone.

case_start "init re-run merge: user scalar wins (fastMode: false)"
reset_user_home
PROJ_SCALAR="$(fresh_project)"
cd "$PROJ_SCALAR"
run_capture "" init --scope project
echo '{"fastMode": false}' > "$PROJ_SCALAR/${CLAUDE_SETTINGS_PATH}"
rm "$PROJ_SCALAR/${STAX_LOCK_PATH}"
run_capture "" init --scope project
SCALAR_BODY="$(cat "$PROJ_SCALAR/${CLAUDE_SETTINGS_PATH}")"
assert_contains "user fastMode=false preserved" "$SCALAR_BODY" '"fastMode": false'
assert_not_contains "bundled fastMode=true rejected" "$SCALAR_BODY" '"fastMode": true'
assert_contains    "bundled hooks still added"       "$SCALAR_BODY" 'stax work-items lint'

# ---------- merge: array entries are unioned, not overwritten ----------
#
# A user-authored hook entry (matcher: Read, calling their own tool) must
# survive AND our bundled Write|Edit|MultiEdit entry must land alongside.
# Both should be present in the resulting PostToolUse array. This is the
# critical case for the merge being additive on arrays.

case_start "init re-run merge: hook arrays are unioned"
reset_user_home
PROJ_ARR="$(fresh_project)"
cd "$PROJ_ARR"
run_capture "" init --scope project
cat > "$PROJ_ARR/${CLAUDE_SETTINGS_PATH}" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Read", "hooks": [{"type": "command", "command": "my-tool"}]}
    ]
  }
}
JSON
rm "$PROJ_ARR/${STAX_LOCK_PATH}"
run_capture "" init --scope project
ARR_BODY="$(cat "$PROJ_ARR/${CLAUDE_SETTINGS_PATH}")"
assert_contains "user matcher Read survives"      "$ARR_BODY" '"matcher": "Read"'
assert_contains "user command my-tool survives"   "$ARR_BODY" '"command": "my-tool"'
assert_contains "bundled matcher Write|Edit|MultiEdit lands" "$ARR_BODY" '"matcher": "Write|Edit|MultiEdit"'
assert_contains "bundled command stax work-items lint lands" "$ARR_BODY" '"command": "stax work-items lint"'

# ---------- merge: malformed JSON leaves the user file untouched ----------
#
# The merge tolerates a broken existing file by failing soft: it logs a
# stderr warning naming the file and leaves the bytes alone. The user's
# intent (whatever they were drafting) survives; they can fix the JSON
# at leisure and re-run init to pick up the bundle additions.

case_start "init re-run merge: malformed JSON preserves user bytes"
reset_user_home
PROJ_BAD="$(fresh_project)"
cd "$PROJ_BAD"
run_capture "" init --scope project
echo 'not valid json {' > "$PROJ_BAD/${CLAUDE_SETTINGS_PATH}"
rm "$PROJ_BAD/${STAX_LOCK_PATH}"
run_capture "" init --scope project
assert_eq "exit 0 despite parse failure" "$RUN_RC" "0"
assert_eq "malformed file untouched" "$(cat "$PROJ_BAD/${CLAUDE_SETTINGS_PATH}")" 'not valid json {'
assert_contains "stderr warns about merge failure" "$RUN_ERR" "merge failed"

# ---------- merge: empty existing file gets seeded with bundle ----------
#
# A user who `touch`ed settings.json (or trimmed it to nothing) and
# re-ran init must end up with the full bundle content — the merge
# treats zero-byte input as `{}` and adds every bundled top-level key.

case_start "init re-run merge: empty existing file is seeded"
reset_user_home
PROJ_EMPTY="$(fresh_project)"
cd "$PROJ_EMPTY"
run_capture "" init --scope project
: > "$PROJ_EMPTY/${CLAUDE_SETTINGS_PATH}"
rm "$PROJ_EMPTY/${STAX_LOCK_PATH}"
run_capture "" init --scope project
EMPTY_BODY="$(cat "$PROJ_EMPTY/${CLAUDE_SETTINGS_PATH}")"
assert_contains "empty file gained fastMode" "$EMPTY_BODY" '"fastMode": true'
assert_contains "empty file gained hook"     "$EMPTY_BODY" 'stax work-items lint'

# ---------- isolation: init re-run keeps user-authored sibling skills ----------

case_start "init re-run keeps user-authored sibling skills"
reset_user_home
PROJ_SIB="$(fresh_project)"
cd "$PROJ_SIB"
run_capture "" init --scope project
mkdir -p "$PROJ_SIB/${CLAUDE_SKILLS_REL}/my-custom" \
         "$PROJ_SIB/${CODEX_SKILLS_REL}/their-custom"
echo "MINE" > "$PROJ_SIB/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
echo "MINE" > "$PROJ_SIB/${CODEX_SKILLS_REL}/their-custom/SKILL.md"
rm "$PROJ_SIB/${STAX_LOCK_PATH}"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_file "sibling claude skill survives re-run" "$PROJ_SIB/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
assert_is_file "sibling agents skill survives re-run" "$PROJ_SIB/${CODEX_SKILLS_REL}/their-custom/SKILL.md"
assert_is_dir  "bundled ${SKILL_SHIP_DIR} present after re-run" \
  "$PROJ_SIB/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"

# ---------- isolation: skill remove leaves foreign content alone ----------

case_start "skill remove leaves foreign content alone"
reset_user_home
PROJ_RMI="$(fresh_project)"
cd "$PROJ_RMI"
run_capture "" init --scope project
mkdir -p "$PROJ_RMI/${CLAUDE_CONFIG_REL}/notes" \
         "$PROJ_RMI/${CODEX_CONFIG_REL}/sessions" \
         "$PROJ_RMI/${CODEX_SKILLS_REL}/their-custom"
echo "USER" > "$PROJ_RMI/${CLAUDE_CONFIG_REL}/CLAUDE.md"
echo "USER" > "$PROJ_RMI/${CLAUDE_CONFIG_REL}/notes/note.txt"
echo "USER" > "$PROJ_RMI/${CLAUDE_SKILLS_REL}/STRAY.md"
echo "USER" > "$PROJ_RMI/${CODEX_CONFIG_REL}/config.toml"
echo "USER" > "$PROJ_RMI/${CODEX_CONFIG_REL}/sessions/s1.json"
echo "USER" > "$PROJ_RMI/${CODEX_SKILLS_REL}/their-custom/SKILL.md"
run_capture "" skills remove --project
assert_eq "exit 0" "$RUN_RC" "0"
for p in \
  "${CLAUDE_CONFIG_REL}/CLAUDE.md" \
  "${CLAUDE_CONFIG_REL}/notes/note.txt" \
  "${CLAUDE_SKILLS_REL}/STRAY.md" \
  "${CLAUDE_SETTINGS_PATH}" \
  "${CODEX_CONFIG_REL}/config.toml" \
  "${CODEX_CONFIG_REL}/sessions/s1.json" \
  "${CODEX_HOOKS_PATH}" \
  "${CODEX_SKILLS_REL}/their-custom/SKILL.md" \
  "${STAX_LOCK_PATH}" \
  "${STAX_SYSTEMS_PATH}"; do
  assert_is_file "skill remove kept $p" "$PROJ_RMI/$p"
done
for skill in $OWNED_SKILLS; do
  assert_absent "skill remove dropped ${CLAUDE_SKILLS_REL}/$skill" "$PROJ_RMI/${CLAUDE_SKILLS_REL}/$skill"
  assert_absent "skill remove dropped ${CODEX_SKILLS_REL}/$skill"  "$PROJ_RMI/${CODEX_SKILLS_REL}/$skill"
done

# ---------- skill remove un-merges bundled hook records ----------
#
# `installAgentConfig` deep-merges our shipped hook records into the user's
# ${CLAUDE_SETTINGS_FILE} / ${CODEX_HOOKS_FILE} on init. `skill remove`
# performs the inverse: subtracts entries that deep-equal a bundled record,
# leaves everything else untouched (user-authored siblings under the same
# event key, top-level non-hook keys, user-added event keys).
#
# The seeded files below mirror the bundled records in agents/claude/
# settings.json and agents/codex/hooks.json. If those embed files change
# form, update this fixture in lockstep — drift surfaces as an assertion
# failure here because the un-merge stops removing the now-stale records.

case_start "skill remove --project un-merges bundled hook records"
reset_user_home
PROJ_UN="$(fresh_project)"
cd "$PROJ_UN"
run_capture "" init --scope project
# Overwrite each JSON with the bundled records (so deep-equal fires) PLUS
# a user-authored hook entry that must survive the un-merge.
cat > "$PROJ_UN/${CLAUDE_SETTINGS_PATH}" <<'EOF'
{
  "fastMode": true,
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "stax work-items lint"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "USER-HOOK"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "stax work-items lint"}]}
    ]
  }
}
EOF
cat > "$PROJ_UN/${CODEX_HOOKS_PATH}" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "apply_patch", "hooks": [{"type": "command", "command": "stax work-items lint"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "stax work-items lint 1>&2"}]},
      {"hooks": [{"type": "command", "command": "USER-CODEX-HOOK"}]}
    ]
  }
}
EOF
run_capture "" skills remove --project
assert_eq       "exit 0"               "$RUN_RC" "0"
assert_contains "summary has unmerged" "$RUN_OUT" "unmerged"
CLAUDE_BODY="$(cat "$PROJ_UN/${CLAUDE_SETTINGS_PATH}")"
CODEX_BODY="$(cat  "$PROJ_UN/${CODEX_HOOKS_PATH}")"
# Top-level non-hook content and user-authored hook entries survive.
assert_contains     "claude fastMode kept"             "$CLAUDE_BODY" '"fastMode": true'
assert_contains     "claude user hook kept"            "$CLAUDE_BODY" 'USER-HOOK'
assert_contains     "codex user hook kept"             "$CODEX_BODY"  'USER-CODEX-HOOK'
# Bundled records are gone: their distinguishing matchers / commands
# no longer appear in either file.
assert_not_contains "claude Write|Edit matcher gone"   "$CLAUDE_BODY" 'Write|Edit|MultiEdit'
assert_not_contains "claude bundled command gone"      "$CLAUDE_BODY" 'stax work-items lint'
assert_not_contains "codex apply_patch matcher gone"   "$CODEX_BODY"  'apply_patch'
assert_not_contains "codex Stop bundled command gone"  "$CODEX_BODY"  'stax work-items lint 1>&2'

# ---------- skill remove leaves a user-tweaked variant alone ----------
#
# If a user copied one of our bundled records and edited the command (or
# matcher), the entry no longer deep-equals the bundle. Un-merge must
# preserve it — the unit of ownership is the leaf record, not the matcher
# or event key.

case_start "skill remove preserves user-tweaked variant of a bundled record"
reset_user_home
PROJ_UNT="$(fresh_project)"
cd "$PROJ_UNT"
run_capture "" init --scope project
cat > "$PROJ_UNT/${CLAUDE_SETTINGS_PATH}" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "stax work-items lint --verbose"}]}
    ]
  }
}
EOF
run_capture "" skills remove --project
assert_eq "exit 0" "$RUN_RC" "0"
TWEAKED_BODY="$(cat "$PROJ_UNT/${CLAUDE_SETTINGS_PATH}")"
assert_contains "tweaked matcher kept" "$TWEAKED_BODY" 'Write|Edit|MultiEdit'
assert_contains "tweaked command kept" "$TWEAKED_BODY" 'stax work-items lint --verbose'

# ---------- Copilot CLI: hooks JSON install + scope-asymmetric paths ----------
#
# Copilot's hook surface is a JSON file (same shape policy as Claude /
# Codex via the existing mergeJSONFile / subtractHooks path) but lands
# at DIFFERENT directories per scope: `.github/hooks/stax.json` at
# project, `~/.copilot/hooks/stax.json` at user (per Copilot CLI's May
# 2026 hooks-configuration docs). The cases below exercise the
# configRelFor(scope) resolver: same JSON contract on both sides, two
# physically different destinations.

case_start "Copilot: init --scope project lands stax.json at .github/hooks/"
reset_user_home
PROJ_CP="$(fresh_project)"
cd "$PROJ_CP"
run_capture "" init --scope project --agents copilot \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq    "exit 0"             "$RUN_RC" "0"
assert_is_file "stax.json present" "$PROJ_CP/${COPILOT_CONFIG_REL}/stax.json"
CP_BODY="$(cat "$PROJ_CP/${COPILOT_CONFIG_REL}/stax.json")"
assert_contains "version present"     "$CP_BODY" '"version"'
assert_contains "postToolUse present" "$CP_BODY" '"postToolUse"'
assert_contains "lint command present" "$CP_BODY" 'stax work-items lint'
# User-scope path must NOT have been touched by a project-scope install.
assert_absent  "user-scope path empty after project install" "$HOME/${COPILOT_USER_CONFIG_REL}/stax.json"

case_start "Copilot: init --scope user lands stax.json at ~/.copilot/hooks/"
reset_user_home
PROJ_CPU="$(fresh_project)"
cd "$PROJ_CPU"
run_capture "" init --scope user --agents copilot \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq    "exit 0"             "$RUN_RC" "0"
assert_is_file "user stax.json present" "$HOME/${COPILOT_USER_CONFIG_REL}/stax.json"
# Project-scope path must NOT have been touched by a user-scope install
# — pins the configRelFor scope split.
assert_absent  "project-scope path empty after user install" "$PROJ_CPU/${COPILOT_CONFIG_REL}/stax.json"

case_start "Copilot: init re-run merges into edited stax.json"
reset_user_home
PROJ_CPM="$(fresh_project)"
cd "$PROJ_CPM"
run_capture "" init --scope project --agents copilot \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq "first init exit 0" "$RUN_RC" "0"
# Overwrite with a user-authored hook entry plus a user-only top-level scalar.
# After re-init: scalar must survive; bundled records re-land; user record stays.
cat > "$PROJ_CPM/${COPILOT_CONFIG_REL}/stax.json" <<'EOF'
{
  "version": 1,
  "userOnlyKey": true,
  "hooks": {
    "postToolUse": [
      {"type": "command", "bash": "user-tool"}
    ]
  }
}
EOF
# Documented re-init flow: delete the lock to unblock the project-marker
# check (mirrors the existing claude/codex merge case). Without this the
# second init exits with "already initialized" before reaching the merge.
rm "$PROJ_CPM/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents copilot \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
CPM_BODY="$(cat "$PROJ_CPM/${COPILOT_CONFIG_REL}/stax.json")"
assert_contains "user scalar survives merge"  "$CPM_BODY" 'userOnlyKey'
assert_contains "user hook survives merge"    "$CPM_BODY" 'user-tool'
assert_contains "bundled hook landed"         "$CPM_BODY" 'stax work-items lint'

case_start "Copilot: skill remove --project un-merges bundled records"
reset_user_home
PROJ_CPR="$(fresh_project)"
cd "$PROJ_CPR"
run_capture "" init --scope project --agents copilot \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Append a user-authored entry; un-merge must drop the bundled one and
# keep the user one.
cat > "$PROJ_CPR/${COPILOT_CONFIG_REL}/stax.json" <<'EOF'
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
EOF
run_capture "" skills remove --project
assert_eq       "exit 0" "$RUN_RC" "0"
CPR_BODY="$(cat "$PROJ_CPR/${COPILOT_CONFIG_REL}/stax.json")"
assert_not_contains "bundled command gone"     "$CPR_BODY" 'stax work-items lint'
assert_contains     "user copilot hook survives" "$CPR_BODY" 'USER-COPILOT-HOOK'
assert_contains     "version scalar survives"   "$CPR_BODY" '"version"'

# ---------- OpenCode plugin: .ts whole-file install + remove ----------
#
# OpenCode's hook surface is a TypeScript plugin file, NOT a JSON
# config. The new installer branch (configTSExt in constants.go) owns
# the file by byte-identity: install copies on absent + no-ops on
# byte-equal + preserves on user-edit; remove deletes on byte-equal
# + preserves on user-edit. Same ownership model as the JSON
# un-merger, just whole-file granularity. Project scope lands at
# `.opencode/plugins/`; user scope diverges to `~/.config/opencode/plugins/`.

case_start "OpenCode: init lands stax.ts at .opencode/plugins/"
reset_user_home
PROJ_OC="$(fresh_project)"
cd "$PROJ_OC"
run_capture "" init --scope project --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq    "exit 0"             "$RUN_RC" "0"
assert_is_file "stax.ts present"   "$PROJ_OC/${OPENCODE_CONFIG_REL}/stax.ts"
OC_BODY="$(cat "$PROJ_OC/${OPENCODE_CONFIG_REL}/stax.ts")"
assert_contains "tool.execute.after present" "$OC_BODY" 'tool.execute.after'
assert_contains "lint command in plugin"     "$OC_BODY" 'stax work-items lint'

case_start "OpenCode: init re-run is byte-equal no-op"
# Stat the file's content + size before re-run; ensure both unchanged.
OC_BODY_FIRST="$(cat "$PROJ_OC/${OPENCODE_CONFIG_REL}/stax.ts")"
rm "$PROJ_OC/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
OC_BODY_SECOND="$(cat "$PROJ_OC/${OPENCODE_CONFIG_REL}/stax.ts")"
assert_eq "stax.ts content stable across re-runs" "$OC_BODY_FIRST" "$OC_BODY_SECOND"

case_start "OpenCode: init preserves user-edited stax.ts"
reset_user_home
PROJ_OCE="$(fresh_project)"
cd "$PROJ_OCE"
run_capture "" init --scope project --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Smallest possible edit (append a comment) to flip byte-equality.
printf '// I customized this\n' >> "$PROJ_OCE/${OPENCODE_CONFIG_REL}/stax.ts"
USER_EDITED="$(cat "$PROJ_OCE/${OPENCODE_CONFIG_REL}/stax.ts")"
rm "$PROJ_OCE/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
OCE_BODY="$(cat "$PROJ_OCE/${OPENCODE_CONFIG_REL}/stax.ts")"
assert_eq       "user edit survives re-run" "$USER_EDITED" "$OCE_BODY"
assert_contains "stderr warned about skip"  "$RUN_ERR"     "user-edited, skipping"

case_start "OpenCode: skill remove deletes byte-equal stax.ts"
reset_user_home
PROJ_OCR="$(fresh_project)"
cd "$PROJ_OCR"
run_capture "" init --scope project --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_is_file "stax.ts present before remove" "$PROJ_OCR/${OPENCODE_CONFIG_REL}/stax.ts"
run_capture "" skills remove --project
assert_eq    "exit 0"                          "$RUN_RC" "0"
assert_absent "stax.ts removed after byte-equal delete" "$PROJ_OCR/${OPENCODE_CONFIG_REL}/stax.ts"

case_start "OpenCode: skill remove preserves user-edited stax.ts"
reset_user_home
PROJ_OCRE="$(fresh_project)"
cd "$PROJ_OCRE"
run_capture "" init --scope project --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
printf '// I customized this\n' >> "$PROJ_OCRE/${OPENCODE_CONFIG_REL}/stax.ts"
USER_EDITED_OCRE="$(cat "$PROJ_OCRE/${OPENCODE_CONFIG_REL}/stax.ts")"
run_capture "" skills remove --project
assert_eq    "exit 0" "$RUN_RC" "0"
OCRE_BODY="$(cat "$PROJ_OCRE/${OPENCODE_CONFIG_REL}/stax.ts")"
assert_eq    "user-edited stax.ts survives remove" "$USER_EDITED_OCRE" "$OCRE_BODY"

case_start "OpenCode: --scope user lands stax.ts at ~/.config/opencode/plugins/"
reset_user_home
PROJ_OCU="$(fresh_project)"
cd "$PROJ_OCU"
run_capture "" init --scope user --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq      "exit 0" "$RUN_RC" "0"
assert_is_file "user stax.ts present" "$HOME/${OPENCODE_USER_CONFIG_REL}/stax.ts"
# Project-scope path must NOT have been touched.
assert_absent  "project-scope stax.ts empty after user install" "$PROJ_OCU/${OPENCODE_CONFIG_REL}/stax.ts"

# ---------- Pi extension: .ts whole-file install + remove ----------
#
# Same install branch as OpenCode (configTSExt path) but lands at Pi's
# documented extension paths: `.pi/extensions/` at project,
# `~/.pi/agent/extensions/` at user (per pi-mono's coding-agent
# docs/extensions.md). Same byte-identity ownership semantics — copy /
# no-op / preserve on install; delete / preserve on remove.

case_start "Pi: init lands stax.ts at .pi/extensions/"
reset_user_home
PROJ_PI="$(fresh_project)"
cd "$PROJ_PI"
run_capture "" init --scope project --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq      "exit 0"           "$RUN_RC" "0"
assert_is_file "stax.ts present"   "$PROJ_PI/${PI_CONFIG_REL}/stax.ts"
PI_BODY="$(cat "$PROJ_PI/${PI_CONFIG_REL}/stax.ts")"
assert_contains "tool_result handler"      "$PI_BODY" 'tool_result'
assert_contains "session_shutdown handler" "$PI_BODY" 'session_shutdown'
assert_contains "lint command in extension" "$PI_BODY" 'stax work-items lint'

case_start "Pi: init re-run is byte-equal no-op"
PI_BODY_FIRST="$(cat "$PROJ_PI/${PI_CONFIG_REL}/stax.ts")"
rm "$PROJ_PI/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
PI_BODY_SECOND="$(cat "$PROJ_PI/${PI_CONFIG_REL}/stax.ts")"
assert_eq "stax.ts content stable across re-runs" "$PI_BODY_FIRST" "$PI_BODY_SECOND"

case_start "Pi: init preserves user-edited stax.ts"
reset_user_home
PROJ_PIE="$(fresh_project)"
cd "$PROJ_PIE"
run_capture "" init --scope project --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
printf '// my customization\n' >> "$PROJ_PIE/${PI_CONFIG_REL}/stax.ts"
PIE_USER="$(cat "$PROJ_PIE/${PI_CONFIG_REL}/stax.ts")"
rm "$PROJ_PIE/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
PIE_BODY="$(cat "$PROJ_PIE/${PI_CONFIG_REL}/stax.ts")"
assert_eq "user-edited stax.ts survives re-run" "$PIE_USER" "$PIE_BODY"

case_start "Pi: skill remove deletes byte-equal stax.ts"
reset_user_home
PROJ_PIR="$(fresh_project)"
cd "$PROJ_PIR"
run_capture "" init --scope project --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_is_file "stax.ts present before remove" "$PROJ_PIR/${PI_CONFIG_REL}/stax.ts"
run_capture "" skills remove --project
assert_eq      "exit 0" "$RUN_RC" "0"
assert_absent  "stax.ts removed after byte-equal delete" "$PROJ_PIR/${PI_CONFIG_REL}/stax.ts"

case_start "Pi: skill remove preserves user-edited stax.ts"
reset_user_home
PROJ_PIRE="$(fresh_project)"
cd "$PROJ_PIRE"
run_capture "" init --scope project --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
printf '// pi customization\n' >> "$PROJ_PIRE/${PI_CONFIG_REL}/stax.ts"
PIRE_USER="$(cat "$PROJ_PIRE/${PI_CONFIG_REL}/stax.ts")"
run_capture "" skills remove --project
assert_eq    "exit 0" "$RUN_RC" "0"
PIRE_BODY="$(cat "$PROJ_PIRE/${PI_CONFIG_REL}/stax.ts")"
assert_eq    "user-edited Pi stax.ts survives remove" "$PIRE_USER" "$PIRE_BODY"

case_start "Pi: --scope user lands stax.ts at ~/.pi/agent/extensions/"
reset_user_home
PROJ_PIU="$(fresh_project)"
cd "$PROJ_PIU"
run_capture "" init --scope user --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq      "exit 0" "$RUN_RC" "0"
assert_is_file "user stax.ts present" "$HOME/${PI_USER_CONFIG_REL}/stax.ts"
assert_absent  "project-scope stax.ts empty after user install" "$PROJ_PIU/${PI_CONFIG_REL}/stax.ts"

# ---------- Google Antigravity: dual user-scope skills + JSON hooks ----------
#
# Antigravity is the only registry row whose `userSkillsRels` carries more
# than one entry — `~/.gemini/antigravity-cli/skills/` for the Antigravity
# CLI's CLI-local skills root and `~/.gemini/config/skills/` for the
# Antigravity tool-family-shared skills root. The install loop in
# installForTarget iterates the slice, so a single `stax init --scope user
# --agents antigravity` must land both bundled skills at BOTH destinations.
# Project scope collapses to the cross-agent `.agents/skills/` (identical
# to Codex/Copilot/Pi/omp/Zed), so a `--agents codex,antigravity` install
# co-locates one shared `.agents/skills/` tree at project scope.
#
# Hook config rides the same JSON-merge slot as Claude (Antigravity reads
# `{"hooks": {...}}` from `.gemini/settings.json` at project, falls back
# to `~/.gemini/settings.json` at user). Re-run merge and skill-remove
# un-merge cases mirror the Claude/Copilot patterns above.

case_start "Antigravity: init --scope project lands skills + settings.json"
reset_user_home
PROJ_AG="$(fresh_project)"
cd "$PROJ_AG"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq      "exit 0" "$RUN_RC" "0"
for skill in ${OWNED_SKILLS}; do
  assert_is_dir "project skill ${skill}" "$PROJ_AG/${ANTIGRAVITY_SKILLS_REL}/${skill}"
  assert_is_file "project SKILL.md ${skill}" \
      "$PROJ_AG/${ANTIGRAVITY_SKILLS_REL}/${skill}/${SKILL_MANIFEST_FILE}"
done
assert_is_file "project settings.json present" \
    "$PROJ_AG/${ANTIGRAVITY_CONFIG_REL}/settings.json"
AG_BODY="$(cat "$PROJ_AG/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_contains "hooks key present"   "$AG_BODY" '"hooks"'
assert_contains "PostToolUse present" "$AG_BODY" '"PostToolUse"'
assert_contains "Stop present"        "$AG_BODY" '"Stop"'
assert_contains "lint command"        "$AG_BODY" 'stax work-items lint'
# Project install must not touch either user-scope skills path or the
# user-scope settings.json (configRelFor returns "$ANTIGRAVITY_CONFIG_REL"
# at both scopes, so user-scope is rooted at $HOME, not $PROJ_AG).
assert_absent  "user-scope CLI skills empty after project install" \
    "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_CLI}/${SKILL_SCOPE_DIR}"
assert_absent  "user-scope shared skills empty after project install" \
    "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_SHARED}/${SKILL_SCOPE_DIR}"
assert_absent  "user-scope settings.json empty after project install" \
    "$HOME/${ANTIGRAVITY_CONFIG_REL}/settings.json"

case_start "Antigravity: init --scope user lands skills at BOTH user roots + settings.json"
reset_user_home
PROJ_AGU="$(fresh_project)"
cd "$PROJ_AGU"
run_capture "" init --scope user --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq "exit 0" "$RUN_RC" "0"
# Both user-scope skill destinations must contain every bundled skill —
# this is the multi-path install assertion. Reading from
# ANTIGRAVITY_USER_SKILLS_REL_CLI and _SHARED proves both `userSkillsRels`
# entries fired.
for skill in ${OWNED_SKILLS}; do
  assert_is_dir "CLI-local skill ${skill}" \
      "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_CLI}/${skill}"
  assert_is_file "CLI-local SKILL.md ${skill}" \
      "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_CLI}/${skill}/${SKILL_MANIFEST_FILE}"
  assert_is_dir "shared skill ${skill}" \
      "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_SHARED}/${skill}"
  assert_is_file "shared SKILL.md ${skill}" \
      "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_SHARED}/${skill}/${SKILL_MANIFEST_FILE}"
done
assert_is_file "user settings.json present" \
    "$HOME/${ANTIGRAVITY_CONFIG_REL}/settings.json"
# Project-scope path must NOT have been touched by a user-scope install.
assert_absent  "project skills empty after user install" \
    "$PROJ_AGU/${ANTIGRAVITY_SKILLS_REL}/${SKILL_SCOPE_DIR}"
assert_absent  "project settings.json empty after user install" \
    "$PROJ_AGU/${ANTIGRAVITY_CONFIG_REL}/settings.json"

case_start "Antigravity: init re-run merges into edited settings.json"
reset_user_home
PROJ_AGM="$(fresh_project)"
cd "$PROJ_AGM"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq "first init exit 0" "$RUN_RC" "0"
# Overwrite with a user-authored hook entry plus a user-only top-level
# scalar. After re-init: scalar must survive; bundled records re-land;
# user record stays — same contract claude/copilot ship.
cat > "$PROJ_AGM/${ANTIGRAVITY_CONFIG_REL}/settings.json" <<'EOF'
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
EOF
rm "$PROJ_AGM/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
AGM_BODY="$(cat "$PROJ_AGM/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_contains "user scalar survives merge"  "$AGM_BODY" 'userOnlyKey'
assert_contains "user hook survives merge"    "$AGM_BODY" 'USER-ANTIGRAVITY-HOOK'
assert_contains "bundled hook landed"         "$AGM_BODY" 'stax work-items lint'

case_start "Antigravity: skill remove --project un-merges bundled records"
reset_user_home
PROJ_AGR="$(fresh_project)"
cd "$PROJ_AGR"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Seed the user file with both bundled-shape and user-authored entries;
# un-merge must drop the bundled ones and keep the user ones. The bundled
# records here MUST stay byte-equal to the records shipped in
# agents/antigravity/settings.json — TestE2EHookFixtureMirrorsBundle
# enforces that invariant from the Go side and points at the exact event
# index that drifted if this heredoc lags behind the bundle.
cat > "$PROJ_AGR/${ANTIGRAVITY_CONFIG_REL}/settings.json" <<'EOF'
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
EOF
run_capture "" skills remove --project
assert_eq           "exit 0" "$RUN_RC" "0"
AGR_BODY="$(cat "$PROJ_AGR/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_not_contains "bundled command gone"         "$AGR_BODY" 'stax work-items lint'
assert_contains     "user antigravity hook survives" "$AGR_BODY" 'USER-ANTIGRAVITY-HOOK'
assert_contains     "user scalar survives un-merge"  "$AGR_BODY" 'userOnlyKey'
# Project skills tree must be cleaned up too; the dual user-scope tree
# is untouched (this case is --project).
assert_absent "project skill scope dir gone" "$PROJ_AGR/${ANTIGRAVITY_SKILLS_REL}/${SKILL_SCOPE_DIR}"

case_start "Antigravity: skill remove --user clears both skills roots"
reset_user_home
PROJ_AGRU="$(fresh_project)"
cd "$PROJ_AGRU"
run_capture "" init --scope user --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Drop a user-authored sibling skill into each user-scope root — the
# allowlist must let it through unharmed while still removing the bundled
# `scope` / `ship` directories.
mkdir -p "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_CLI}/my-skill"
mkdir -p "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_SHARED}/my-skill"
: > "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_CLI}/my-skill/${SKILL_MANIFEST_FILE}"
: > "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_SHARED}/my-skill/${SKILL_MANIFEST_FILE}"
run_capture "" skills remove --user
assert_eq "exit 0" "$RUN_RC" "0"
for skill in ${OWNED_SKILLS}; do
  assert_absent "CLI-local ${skill} gone" \
      "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_CLI}/${skill}"
  assert_absent "shared ${skill} gone" \
      "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_SHARED}/${skill}"
done
assert_is_dir "user-authored sibling preserved (CLI root)" \
    "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_CLI}/my-skill"
assert_is_dir "user-authored sibling preserved (shared root)" \
    "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_SHARED}/my-skill"

# ---------- Antigravity: surgical merge / un-merge contract ----------
#
# Antigravity rides the same JSON-merge primitive as Claude / Codex /
# Copilot. The Claude block earlier in the file pins eight contract-level
# cases (idempotent re-run, user-scalar-wins, array-union, malformed-
# tolerance, empty-seed, foreign-content-preserve, user-tweaked-variant-
# preserve, user-scope merge). Antigravity must satisfy each of them —
# the merge code is shared, but a regression in the dispatch / extension
# / scope-resolution layer could break ONE agent without breaking another,
# so each agent that ships through this primitive gets its own coverage.

case_start "Antigravity: init re-run is idempotent on merged settings.json"
reset_user_home
PROJ_AGIDEM="$(fresh_project)"
cd "$PROJ_AGIDEM"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Drop a user scalar so the merge path executes (vs the fresh-copy path).
echo '{"model": "gemini-2.5-pro"}' > "$PROJ_AGIDEM/${ANTIGRAVITY_CONFIG_REL}/settings.json"
rm "$PROJ_AGIDEM/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
SNAP_AG_1="$(cat "$PROJ_AGIDEM/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
# Second re-run must be a byte-level no-op — array-union dedup catches
# every bundled entry already present from the first merge.
rm "$PROJ_AGIDEM/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
SNAP_AG_2="$(cat "$PROJ_AGIDEM/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_eq "settings.json idempotent across re-runs" "$SNAP_AG_1" "$SNAP_AG_2"

case_start "Antigravity: init re-run merge: hook arrays are unioned"
reset_user_home
PROJ_AGARR="$(fresh_project)"
cd "$PROJ_AGARR"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Seed a user-authored hook entry that doesn't deep-equal anything we ship.
# After re-init the bundled Write|Edit entry AND the user's Read entry
# must coexist in PostToolUse — that's the additive-array contract.
cat > "$PROJ_AGARR/${ANTIGRAVITY_CONFIG_REL}/settings.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Read", "hooks": [{"type": "command", "command": "my-tool"}]}
    ]
  }
}
JSON
rm "$PROJ_AGARR/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
AGARR_BODY="$(cat "$PROJ_AGARR/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_contains "user matcher Read survives"          "$AGARR_BODY" '"matcher": "Read"'
assert_contains "user command my-tool survives"       "$AGARR_BODY" '"command": "my-tool"'
assert_contains "bundled matcher Write|Edit lands"    "$AGARR_BODY" '"matcher": "Write|Edit"'
assert_contains "bundled command stax work-items lint lands" "$AGARR_BODY" '"command": "stax work-items lint"'

case_start "Antigravity: init re-run merge: user scalar wins on conflict"
reset_user_home
PROJ_AGSCALAR="$(fresh_project)"
cd "$PROJ_AGSCALAR"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Bundled settings.json carries no scalar today, so seed a hypothetical
# user override that COULD conflict if the bundle ever gains one. The
# point is the merge path's "existing scalar wins" rule — any future
# bundled top-level scalar must NOT clobber a user value.
echo '{"model": "gemini-3-flash", "hooks": {}}' > "$PROJ_AGSCALAR/${ANTIGRAVITY_CONFIG_REL}/settings.json"
rm "$PROJ_AGSCALAR/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
AGSCALAR_BODY="$(cat "$PROJ_AGSCALAR/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_contains "user model scalar preserved"      "$AGSCALAR_BODY" '"model": "gemini-3-flash"'
assert_contains "bundled hooks still added"        "$AGSCALAR_BODY" 'stax work-items lint'

case_start "Antigravity: init re-run merge: malformed JSON preserves user bytes"
reset_user_home
PROJ_AGBAD="$(fresh_project)"
cd "$PROJ_AGBAD"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
echo 'not valid json {' > "$PROJ_AGBAD/${ANTIGRAVITY_CONFIG_REL}/settings.json"
rm "$PROJ_AGBAD/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq "exit 0 despite parse failure" "$RUN_RC" "0"
assert_eq "malformed file untouched" "$(cat "$PROJ_AGBAD/${ANTIGRAVITY_CONFIG_REL}/settings.json")" 'not valid json {'
assert_contains "stderr warns about merge failure" "$RUN_ERR" "merge failed"

case_start "Antigravity: init re-run merge: empty existing file is seeded"
reset_user_home
PROJ_AGEMPTY="$(fresh_project)"
cd "$PROJ_AGEMPTY"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
: > "$PROJ_AGEMPTY/${ANTIGRAVITY_CONFIG_REL}/settings.json"
rm "$PROJ_AGEMPTY/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
AGEMPTY_BODY="$(cat "$PROJ_AGEMPTY/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_contains "empty file gained hooks key"  "$AGEMPTY_BODY" '"hooks"'
assert_contains "empty file gained bundled hook" "$AGEMPTY_BODY" 'stax work-items lint'

case_start "Antigravity: init re-run keeps user-authored sibling skills"
reset_user_home
PROJ_AGSIB="$(fresh_project)"
cd "$PROJ_AGSIB"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
mkdir -p "$PROJ_AGSIB/${ANTIGRAVITY_SKILLS_REL}/my-custom"
echo "MINE" > "$PROJ_AGSIB/${ANTIGRAVITY_SKILLS_REL}/my-custom/${SKILL_MANIFEST_FILE}"
rm "$PROJ_AGSIB/${STAX_LOCK_PATH}"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_file "sibling antigravity skill survives re-run" \
    "$PROJ_AGSIB/${ANTIGRAVITY_SKILLS_REL}/my-custom/${SKILL_MANIFEST_FILE}"
assert_is_dir  "bundled ${SKILL_SHIP_DIR} present after re-run" \
    "$PROJ_AGSIB/${ANTIGRAVITY_SKILLS_REL}/${SKILL_SHIP_DIR}"

case_start "Antigravity: skill remove leaves foreign content under .gemini alone"
reset_user_home
PROJ_AGRMI="$(fresh_project)"
cd "$PROJ_AGRMI"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Foreign files the user dropped into the same parent directories must
# survive skill remove — un-merge is recordset-scoped on the JSON, the
# skill walk is allowlist-scoped on the directory entries.
mkdir -p "$PROJ_AGRMI/${ANTIGRAVITY_CONFIG_REL}/notes"
echo "USER" > "$PROJ_AGRMI/${ANTIGRAVITY_CONFIG_REL}/GEMINI.md"
echo "USER" > "$PROJ_AGRMI/${ANTIGRAVITY_CONFIG_REL}/notes/note.txt"
echo "USER" > "$PROJ_AGRMI/${ANTIGRAVITY_SKILLS_REL}/STRAY.md"
run_capture "" skills remove --project
assert_eq "exit 0" "$RUN_RC" "0"
for p in \
  "${ANTIGRAVITY_CONFIG_REL}/GEMINI.md" \
  "${ANTIGRAVITY_CONFIG_REL}/notes/note.txt" \
  "${ANTIGRAVITY_SKILLS_REL}/STRAY.md" \
  "${STAX_LOCK_PATH}" \
  "${STAX_SYSTEMS_PATH}"; do
  assert_is_file "skill remove kept $p" "$PROJ_AGRMI/$p"
done
for skill in $OWNED_SKILLS; do
  assert_absent "skill remove dropped ${ANTIGRAVITY_SKILLS_REL}/$skill" \
      "$PROJ_AGRMI/${ANTIGRAVITY_SKILLS_REL}/$skill"
done

case_start "Antigravity: skill remove preserves user-tweaked variant of a bundled record"
reset_user_home
PROJ_AGUNT="$(fresh_project)"
cd "$PROJ_AGUNT"
run_capture "" init --scope project --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# Tweak the command (`--verbose` suffix) so the record no longer
# deep-equals the bundle. Un-merge must NOT drop it — ownership is the
# leaf record, not the matcher or the event key.
cat > "$PROJ_AGUNT/${ANTIGRAVITY_CONFIG_REL}/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "stax work-items lint --verbose"}]}
    ]
  }
}
EOF
run_capture "" skills remove --project
assert_eq "exit 0" "$RUN_RC" "0"
TWEAKED_AG_BODY="$(cat "$PROJ_AGUNT/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_contains "tweaked matcher kept" "$TWEAKED_AG_BODY" 'Write|Edit'
assert_contains "tweaked command kept" "$TWEAKED_AG_BODY" 'stax work-items lint --verbose'

case_start "Antigravity: init --scope user re-run merges edited settings.json"
reset_user_home
PROJ_AGUMERGE="$(fresh_project)"
cd "$PROJ_AGUMERGE"
run_capture "" init --scope user --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
# User-scope merge: same contract as the project-scope case but the
# destination lives under $HOME and the user-scope skill paths must
# remain populated at BOTH antigravity user-scope roots.
echo '{"USER": "EDIT", "model": "gemini-3-pro"}' > "$HOME/${ANTIGRAVITY_CONFIG_REL}/settings.json"
rm "$PROJ_AGUMERGE/${STAX_LOCK_PATH}"
run_capture "" init --scope user --agents antigravity \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq "exit 0" "$RUN_RC" "0"
USER_AG_BODY="$(cat "$HOME/${ANTIGRAVITY_CONFIG_REL}/settings.json")"
assert_contains "user-scope settings.json keeps USER key"    "$USER_AG_BODY" '"USER": "EDIT"'
assert_contains "user-scope settings.json keeps model"       "$USER_AG_BODY" '"model": "gemini-3-pro"'
assert_contains "user-scope settings.json gains hook"        "$USER_AG_BODY" 'stax work-items lint'
# Skills tree at BOTH user-scope discovery roots must still be populated
# after the second install pass — the multi-destination loop is exercised
# again under merge conditions.
for skill in ${OWNED_SKILLS}; do
  assert_is_file "user-scope CLI ${skill} after merge re-run" \
      "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_CLI}/${skill}/${SKILL_MANIFEST_FILE}"
  assert_is_file "user-scope shared ${skill} after merge re-run" \
      "$HOME/${ANTIGRAVITY_USER_SKILLS_REL_SHARED}/${skill}/${SKILL_MANIFEST_FILE}"
done

# ---------- isolation: lazy first-run write keeps foreign content ----------
#
# Lazy first-run is "create iff missing" — it never touches a tree that
# already exists. Foreign files dropped into ~/${STAX_AGENTS_DIR} after the
# first run survive subsequent bare invocations *until* the hourly refresh
# fires (covered by the next case). Without a .config.json present,
# maybeNotifyUpdate returns early and the refresh never runs.
#
# `--version` is the seed-and-exit driver these cases reach for now that
# bare `stax` / `stax --no-browser` block on the loopback server.
# --version fires ensureBundledAgents AND maybeNotifyUpdate but exits
# cleanly after printing the notice — same code coverage, no need for
# the bg_spawn_stax dance.

case_start "lazy first-run write leaves foreign content under \$HOME/${STAX_AGENTS_DIR} alone"
reset_user_home
run_capture "" --version
assert_is_dir "agents dir exists" "$HOME/${STAX_AGENTS_DIR}"
echo "USER" > "$HOME/${STAX_AGENTS_DIR}/USER-NOTE.md"
mkdir -p "$HOME/${STAX_AGENTS_DIR}/my-private-skill"
echo "USER" > "$HOME/${STAX_AGENTS_DIR}/my-private-skill/SKILL.md"
# --version with no .config.json → no update check → no refresh.
run_capture "" --version
assert_is_file "user file survives without hourly refresh" \
  "$HOME/${STAX_AGENTS_DIR}/USER-NOTE.md"
assert_is_file "user skill survives without hourly refresh" \
  "$HOME/${STAX_AGENTS_DIR}/my-private-skill/SKILL.md"

# ---------- hourly update check rewrites $HOME/<STAX_AGENTS_DIR> from embed ----------

case_start "hourly update check rewrites bundled agents tree"
reset_user_home
PROJ_REF="$(fresh_project)"
# 1) Lazy first-run write seeds the agents tree.
run_capture "" --version
assert_is_dir "agents tree seeded" "$HOME/${STAX_AGENTS_DIR}"
# 2) Install project skills so we can verify the refresh DOESN'T touch them.
cd "$PROJ_REF"
run_capture "" init --agents=claude,codex --scope=project
echo "MINE" > "$PROJ_REF/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}/PROJECT-LOCAL"
# 3) Drop a stale file under the global tree — the hourly refresh must wipe it.
echo "STALE" > "$HOME/${STAX_AGENTS_DIR}/STALE.md"
# 4) Backdate .config.json so the hourly cadence triggers immediately. The
#    binary's stamped version is recorded so no upgrade nudge fires.
echo "{\"version\":\"${E2E_VERSION}\",\"last_checked\":0}" \
  > "$HOME/${STAX_DIR}/${STAX_CONFIG_FILE}"
# 5) --version fires the update check → writeBundledAgents(true).
run_capture "" --version
assert_eq "exit 0" "$RUN_RC" "0"
assert_absent "stale file wiped by hourly refresh" "$HOME/${STAX_AGENTS_DIR}/STALE.md"
assert_is_dir "bundled skill present after refresh" \
  "$HOME/${STAX_AGENTS_SKILLS_DIR}/${SKILL_SHIP_DIR}"
# 6) Project-local content MUST be untouched.
assert_is_file "project-local file untouched by global refresh" \
  "$PROJ_REF/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}/PROJECT-LOCAL"
# 7) last_checked got bumped → a second back-to-back run does NOT refresh.
echo "POST" > "$HOME/${STAX_AGENTS_DIR}/POST.md"
run_capture "" --version
assert_is_file "post-check sentinel survives next --version run" \
  "$HOME/${STAX_AGENTS_DIR}/POST.md"

# ---------- isolation: init --scope user keeps foreign $HOME content ----------

case_start "init --scope user leaves foreign \$HOME content alone"
reset_user_home
cd "$(fresh_project)"
mkdir -p "$HOME/${CLAUDE_CONFIG_REL}/notes" \
         "$HOME/${CLAUDE_SKILLS_REL}/my-custom" \
         "$HOME/${CODEX_SKILLS_REL}/another-custom" \
         "$HOME/${CODEX_CONFIG_REL}/sessions"
echo "USER" > "$HOME/${CLAUDE_CONFIG_REL}/CLAUDE.md"
echo "USER" > "$HOME/${CLAUDE_CONFIG_REL}/notes/note.txt"
echo "USER" > "$HOME/${CLAUDE_SKILLS_REL}/STRAY.md"
echo "USER" > "$HOME/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
echo "USER" > "$HOME/${CODEX_SKILLS_PARENT}/something.yaml"
echo "USER" > "$HOME/${CODEX_SKILLS_REL}/another-custom/SKILL.md"
echo "USER" > "$HOME/${CODEX_CONFIG_REL}/config.toml"
echo "USER" > "$HOME/${CODEX_CONFIG_REL}/sessions/s1.json"
run_capture "" init --scope user
assert_eq "exit 0" "$RUN_RC" "0"
for p in \
  "${CLAUDE_CONFIG_REL}/CLAUDE.md" \
  "${CLAUDE_CONFIG_REL}/notes/note.txt" \
  "${CLAUDE_SKILLS_REL}/STRAY.md" \
  "${CLAUDE_SKILLS_REL}/my-custom/SKILL.md" \
  "${CODEX_SKILLS_PARENT}/something.yaml" \
  "${CODEX_SKILLS_REL}/another-custom/SKILL.md" \
  "${CODEX_CONFIG_REL}/config.toml" \
  "${CODEX_CONFIG_REL}/sessions/s1.json"; do
  assert_is_file "user-scope preserved $p" "$HOME/$p"
  assert_eq      "user-scope content $p"   "$(cat "$HOME/$p")" "USER"
done
assert_is_symlink "user-scope bundled ${SKILL_SHIP_DIR}"    "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_symlink "user-scope bundled ${SKILL_SCOPE_DIR}" "$HOME/${CODEX_SKILLS_REL}/${SKILL_SCOPE_DIR}"

# ---------- isolation: init --scope user re-run preserves user edits ----------

case_start "init --scope user re-run merges edited ${CLAUDE_SETTINGS_FILE} + ${CODEX_HOOKS_FILE}"
reset_user_home
PROJ_USER_MERGE="$(fresh_project)"
cd "$PROJ_USER_MERGE"
run_capture "" init --scope user
echo '{"USER": "EDIT"}' > "$HOME/${CLAUDE_SETTINGS_PATH}"
echo '{"USER": "EDIT"}' > "$HOME/${CODEX_HOOKS_PATH}"
# Even under --scope user, init writes .stax/ into cwd — the project
# marker check is keyed on the cwd-local lock regardless of skill scope.
rm "$PROJ_USER_MERGE/${STAX_LOCK_PATH}"
run_capture "" init --scope user
assert_eq "exit 0" "$RUN_RC" "0"
USER_CLAUDE_BODY="$(cat "$HOME/${CLAUDE_SETTINGS_PATH}")"
USER_CODEX_BODY="$(cat "$HOME/${CODEX_HOOKS_PATH}")"
# Same contract as the project-scope merge case, but the destination is
# under $HOME (user-scope install). User key survives + bundle keys land.
assert_contains "user ${CLAUDE_SETTINGS_FILE} keeps user key" "$USER_CLAUDE_BODY" '"USER": "EDIT"'
assert_contains "user ${CLAUDE_SETTINGS_FILE} gains fastMode" "$USER_CLAUDE_BODY" '"fastMode": true'
assert_contains "user ${CLAUDE_SETTINGS_FILE} gains hook"     "$USER_CLAUDE_BODY" 'stax work-items lint'
assert_contains "user ${CODEX_HOOKS_FILE} keeps user key"     "$USER_CODEX_BODY"  '"USER": "EDIT"'
assert_contains "user ${CODEX_HOOKS_FILE} gains hook"         "$USER_CODEX_BODY"  'stax work-items lint'

# ---------- isolation: init --scope user re-run keeps sibling skills ----------

case_start "init --scope user re-run keeps user-authored sibling skills"
reset_user_home
PROJ_USER_SIB="$(fresh_project)"
cd "$PROJ_USER_SIB"
run_capture "" init --scope user
mkdir -p "$HOME/${CLAUDE_SKILLS_REL}/my-custom"
echo "MINE" > "$HOME/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
rm "$PROJ_USER_SIB/${STAX_LOCK_PATH}"
run_capture "" init --scope user
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_file    "user-scope sibling survives re-run" "$HOME/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
assert_is_symlink "user-scope bundled still symlinked" "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"

# ---------- skills remove --user un-merges hooks from every shipped config ----------
#
# The corresponding project-scope un-merge cases above pin un-merge for
# claude+codex (line ~1619), copilot (~1764), opencode (~1840/1851), and
# pi (~1918/1929). The user-scope counterpart wasn't exercised on either
# runner — `skills remove --user` walks every agentTargets row with a
# configSrc and consults `configRelFor(scopeUser)` for the destination,
# which is the only branch where Copilot's userConfigRel override
# (`.copilot/hooks/`) actually drives a different path than configRel
# (`.github/hooks/`). The cases below close that gap for all five
# hook-shipping agents. Each one:
#   1. Installs --scope user so the bundled config lands at the
#      user-scope path (different file per agent).
#   2. Mutates the user file to add a user-authored sibling record /
#      user-tweaked variant — both must survive the un-merge.
#   3. Runs `skills remove --user` and asserts the bundled record is
#      gone, the user record survives, and any top-level scalar is
#      preserved.

case_start "skills remove --user un-merges bundled hooks from user ${CLAUDE_SETTINGS_FILE}"
reset_user_home
PROJ_RM_USER_CL="$(fresh_project)"
cd "$PROJ_RM_USER_CL"
run_capture "" init --scope user
# Append a user-authored Bash record alongside our bundled
# Write|Edit|MultiEdit record so we can assert it survives.
cat > "$HOME/${CLAUDE_SETTINGS_PATH}" <<'EOF'
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
EOF
run_capture "" skills remove --user
assert_eq           "exit 0"                                "$RUN_RC" "0"
USER_CL_BODY="$(cat "$HOME/${CLAUDE_SETTINGS_PATH}")"
assert_contains     "user-scope fastMode kept"              "$USER_CL_BODY" '"fastMode": true'
assert_contains     "user-scope Bash record survives"       "$USER_CL_BODY" 'USER-CLAUDE-USER-HOOK'
assert_not_contains "user-scope bundled command gone"       "$USER_CL_BODY" 'stax work-items lint'

case_start "skills remove --user un-merges bundled hooks from user ${CODEX_HOOKS_FILE}"
reset_user_home
PROJ_RM_USER_CX="$(fresh_project)"
cd "$PROJ_RM_USER_CX"
run_capture "" init --scope user
cat > "$HOME/${CODEX_HOOKS_PATH}" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "apply_patch", "hooks": [{"type": "command", "command": "stax work-items lint"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "stax work-items lint 1>&2"}]},
      {"hooks": [{"type": "command", "command": "USER-CODEX-USER-HOOK"}]}
    ]
  }
}
EOF
run_capture "" skills remove --user
assert_eq           "exit 0"                                "$RUN_RC" "0"
USER_CX_BODY="$(cat "$HOME/${CODEX_HOOKS_PATH}")"
assert_contains     "user-scope codex user hook survives"   "$USER_CX_BODY" 'USER-CODEX-USER-HOOK'
assert_not_contains "user-scope apply_patch matcher gone"   "$USER_CX_BODY" 'apply_patch'
assert_not_contains "user-scope Stop bundled command gone"  "$USER_CX_BODY" 'stax work-items lint 1>&2'

case_start "skills remove --user un-merges bundled hooks from user Copilot stax.json"
reset_user_home
PROJ_RM_USER_CP="$(fresh_project)"
cd "$PROJ_RM_USER_CP"
# Copilot is the canonical scope-asymmetric case — `userConfigRel`
# diverts the user-scope install to .copilot/hooks/ rather than the
# project's .github/hooks/. This case proves un-merge follows the
# same resolver (so install and remove can't drift across scopes).
run_capture "" init --scope user --agents copilot \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_file "user copilot stax.json present" "$HOME/${COPILOT_USER_CONFIG_REL}/stax.json"
cat > "$HOME/${COPILOT_USER_CONFIG_REL}/stax.json" <<'EOF'
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
EOF
run_capture "" skills remove --user
assert_eq           "exit 0"                                "$RUN_RC" "0"
USER_CP_BODY="$(cat "$HOME/${COPILOT_USER_CONFIG_REL}/stax.json")"
assert_contains     "user-scope copilot user hook survives" "$USER_CP_BODY" 'USER-COPILOT-USER-HOOK'
assert_not_contains "user-scope copilot bundled cmd gone"   "$USER_CP_BODY" 'stax work-items lint'
assert_contains     "user-scope version scalar survives"    "$USER_CP_BODY" '"version"'

case_start "skills remove --user deletes byte-equal user OpenCode stax.ts"
reset_user_home
PROJ_RM_USER_OC="$(fresh_project)"
cd "$PROJ_RM_USER_OC"
run_capture "" init --scope user --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq      "exit 0" "$RUN_RC" "0"
assert_is_file "user opencode stax.ts present" "$HOME/${OPENCODE_USER_CONFIG_REL}/stax.ts"
run_capture "" skills remove --user
assert_eq      "exit 0" "$RUN_RC" "0"
assert_absent  "user opencode stax.ts removed (byte-equal)" "$HOME/${OPENCODE_USER_CONFIG_REL}/stax.ts"

case_start "skills remove --user preserves user-edited OpenCode stax.ts"
reset_user_home
PROJ_RM_USER_OCE="$(fresh_project)"
cd "$PROJ_RM_USER_OCE"
run_capture "" init --scope user --agents opencode \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
printf '// my user-scope customization\n' >> "$HOME/${OPENCODE_USER_CONFIG_REL}/stax.ts"
USER_OCE_EDITED="$(cat "$HOME/${OPENCODE_USER_CONFIG_REL}/stax.ts")"
run_capture "" skills remove --user
assert_eq "exit 0" "$RUN_RC" "0"
USER_OCE_BODY="$(cat "$HOME/${OPENCODE_USER_CONFIG_REL}/stax.ts")"
assert_eq "user-edited user-scope stax.ts survives remove" "$USER_OCE_EDITED" "$USER_OCE_BODY"

case_start "skills remove --user deletes byte-equal user Pi stax.ts"
reset_user_home
PROJ_RM_USER_PI="$(fresh_project)"
cd "$PROJ_RM_USER_PI"
run_capture "" init --scope user --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
assert_eq      "exit 0" "$RUN_RC" "0"
assert_is_file "user pi stax.ts present" "$HOME/${PI_USER_CONFIG_REL}/stax.ts"
run_capture "" skills remove --user
assert_eq      "exit 0" "$RUN_RC" "0"
assert_absent  "user pi stax.ts removed (byte-equal)" "$HOME/${PI_USER_CONFIG_REL}/stax.ts"

case_start "skills remove --user preserves user-edited Pi stax.ts"
reset_user_home
PROJ_RM_USER_PIE="$(fresh_project)"
cd "$PROJ_RM_USER_PIE"
run_capture "" init --scope user --agents pi \
    --prefix-width 4 --max-work-item-lines 30 --review-per task
printf '// pi user-scope customization\n' >> "$HOME/${PI_USER_CONFIG_REL}/stax.ts"
USER_PIE_EDITED="$(cat "$HOME/${PI_USER_CONFIG_REL}/stax.ts")"
run_capture "" skills remove --user
assert_eq "exit 0" "$RUN_RC" "0"
USER_PIE_BODY="$(cat "$HOME/${PI_USER_CONFIG_REL}/stax.ts")"
assert_eq "user-edited user-scope Pi stax.ts survives remove" "$USER_PIE_EDITED" "$USER_PIE_BODY"

# ---------- skill remove on empty state ----------

case_start "skill remove --user is a silent no-op when nothing is installed"
reset_user_home
# Trigger the lazy first-run write of ~/${STAX_DIR}/agents/ via
# --version (bare stax now blocks on the loopback server), then wipe
# the install dirs so skill remove has nothing to do.
run_capture "" --version
rm -rf "$HOME/${CLAUDE_CONFIG_REL}" "$HOME/${CODEX_SKILLS_PARENT}" "$HOME/${CODEX_CONFIG_REL}" "$HOME/${OPENCODE_SKILLS_PARENT}"
run_capture "" skills remove --user
assert_eq "exit 0 on empty state" "$RUN_RC" "0"
assert_contains "summary line" "$RUN_OUT" "Removed 0"

case_start "skill remove --project outside a stax project"
reset_user_home
cd "$(fresh_project)"
run_capture "" skills remove --project
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not a stax project"
assert_contains "hint"       "$RUN_ERR" "stax init"

case_start "skill remove --project is a silent no-op when only the scaffold exists"
reset_user_home
PROJ_RM_EMPTY="$(fresh_project)"
seed_project_scaffold "$PROJ_RM_EMPTY"
cd "$PROJ_RM_EMPTY"
run_capture "" skills remove --project
assert_eq "exit 0 on empty state" "$RUN_RC" "0"
assert_contains "summary line" "$RUN_OUT" "Removed 0"

# ---------- idempotency: re-running has zero net effect ----------

case_start "stax --version is idempotent (no re-bootstrap)"
reset_user_home
run_capture "" --version
sentinel_path="$HOME/${STAX_AGENTS_SKILLS_DIR}/${SKILL_SHIP_DIR}/SKILL.md"
# stat is non-portable: BSD/macOS uses `-f %m`, GNU/Linux uses `-c %Y`. The
# prior `stat -f %m … || stat -c %Y …` form looked clever but broke on Linux
# — GNU's `-f` flag means "filesystem status" (a multi-line block of free-
# block counts etc.) and treats `%m` as a second file argument, so the LHS
# exits 0 with garbage output and the fallback never fires. Branch on OS
# explicitly so each path gets just the mtime epoch.
read_mtime() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}
first_mtime="$(read_mtime "$sentinel_path")"
sleep 1
run_capture "" --version
second_mtime="$(read_mtime "$sentinel_path")"
assert_eq "mtime unchanged across runs" "$first_mtime" "$second_mtime"

case_start "init refuses re-run on an initialized project (lock-file marker)"
reset_user_home
PROJ_IDEM="$(fresh_project)"
cd "$PROJ_IDEM"
run_capture "" init --scope project
assert_eq "first init exit 0" "$RUN_RC" "0"
assert_exists "lock written" "$PROJ_IDEM/${STAX_LOCK_PATH}"
# Seed the systems registry with content so we can later verify init
# never overwrites it on the post-lock-deletion re-run.
echo "systems:" > "$PROJ_IDEM/${STAX_SYSTEMS_PATH}"
echo "  - name: payments" >> "$PROJ_IDEM/${STAX_SYSTEMS_PATH}"
systems_before="$(cat "$PROJ_IDEM/${STAX_SYSTEMS_PATH}")"
run_capture "" init --scope project
assert_eq "second init refused (exit 2)" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "already initialized"
assert_contains "hint mentions ${STAX_LOCK_FILE}" "$RUN_ERR" "${STAX_LOCK_FILE}"

case_start "init re-runs after lock file deletion, preserving ${STAX_SYSTEMS_FILE}"
rm "$PROJ_IDEM/${STAX_LOCK_PATH}"
run_capture "" init --scope project
assert_eq "exit 0 after lock removed" "$RUN_RC" "0"
assert_exists "lock recreated" "$PROJ_IDEM/${STAX_LOCK_PATH}"
systems_after="$(cat "$PROJ_IDEM/${STAX_SYSTEMS_PATH}")"
assert_eq "${STAX_SYSTEMS_FILE} untouched across re-init" "$systems_before" "$systems_after"

# ---------- CLI flag forms ----------

case_start "--scope=project (equals form)"
reset_user_home
PROJ_EQ="$(fresh_project)"
cd "$PROJ_EQ"
run_capture "" init --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "scope=project installed" "$PROJ_EQ/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"

case_start "--scope=user (equals form)"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
assert_exists "scope=user installed" "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"

# ---------- init runs cleanly when $HOME/${STAX_AGENTS_DIR} is missing ----------

case_start "init bootstraps \$HOME/${STAX_AGENTS_DIR} on first run"
reset_user_home
assert_absent "agents dir starts missing" "$HOME/${STAX_AGENTS_DIR}"
cd "$(fresh_project)"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "init materialized agents" "$HOME/${STAX_AGENTS_SKILLS_DIR}/${SKILL_SHIP_DIR}"

# ---------- stream discipline: stdout vs stderr ----------

case_start "stax --version writes nothing to stderr on a clean run"
reset_user_home
run_capture "" --version
[ -z "$RUN_ERR" ] && ok "stderr empty" || fail "stderr empty" "got: $RUN_ERR"

case_start "init --scope project writes progress to stdout, not stderr"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project
assert_contains "progress on stdout" "$RUN_OUT" "Installing"
assert_not_contains "no progress on stderr" "$RUN_ERR" "Installing"

case_start "project + user scopes coexist; project copies are not symlinks"
# Run user-scope init from a throwaway cwd. Then move to a fresh project
# dir for project-scope init. All four install roots must end up
# populated with each bundled skill's SKILL.md, and the project-scope
# copies must be regular files (not symlinks back into ~/.stax/agents/) —
# otherwise a hand-edit at project scope would silently propagate to
# every other project on the machine.
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope=user   --agents=claude,codex
assert_eq "user init exit 0"    "$RUN_RC" "0"
PROJ_SD7="$(fresh_project)"
cd "$PROJ_SD7"
run_capture "" init --scope=project --agents=claude,codex
assert_eq "project init exit 0" "$RUN_RC" "0"
for skill in $OWNED_SKILLS; do
  manifest="${skill}/${SKILL_MANIFEST_FILE}"
  assert_is_file "project Claude $manifest exists"  "$PROJ_SD7/${CLAUDE_SKILLS_REL}/${manifest}"
  assert_is_file "project Codex $manifest exists"   "$PROJ_SD7/${CODEX_SKILLS_REL}/${manifest}"
  assert_exists  "user Claude $manifest exists"     "$HOME/${CLAUDE_SKILLS_REL}/${manifest}"
  assert_exists  "user Codex $manifest exists"      "$HOME/${CODEX_SKILLS_REL}/${manifest}"
  # Project-scope must be a regular file (not a symlink). User-scope is
  # allowed to be a symlink (it's how cross-project refresh propagates).
  [ ! -L "$PROJ_SD7/${CLAUDE_SKILLS_REL}/${manifest}" ] \
    && ok "project Claude $manifest is not a symlink" \
    || fail "project Claude $manifest is not a symlink" "found symlink — project copy would track user-scope edits"
  [ ! -L "$PROJ_SD7/${CODEX_SKILLS_REL}/${manifest}" ] \
    && ok "project Codex $manifest is not a symlink" \
    || fail "project Codex $manifest is not a symlink" "found symlink — project copy would track user-scope edits"
done

case_start "project SKILL.md edits survive a hourly user-scope refresh"
# Hand-edit a project-scope SKILL.md with a sentinel byte. Trigger the
# hourly refresh that wholesale-rewrites ~/.stax/agents/. The project copy
# must retain the sentinel; the user-scope copy (a symlink into the
# refreshed bundled tree) must reflect the embed bytes again.
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope=user   --agents=claude,codex
PROJ_SD8="$(fresh_project)"
cd "$PROJ_SD8"
run_capture "" init --scope=project --agents=claude,codex
sentinel_doc="$PROJ_SD8/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}/${SKILL_MANIFEST_FILE}"
printf '\n<!-- e2e sentinel: PROJECT-EDITED -->\n' >> "$sentinel_doc"
# Backdate .config.json so the next stax invocation fires the hourly refresh.
echo "{\"version\":\"${E2E_VERSION}\",\"last_checked\":0}" \
  > "$HOME/${STAX_DIR}/${STAX_CONFIG_FILE}"
run_capture "" --version
assert_eq "--version exit 0" "$RUN_RC" "0"
# Project copy must still contain the sentinel.
project_body="$(cat "$sentinel_doc")"
assert_contains "project sentinel survives refresh" "$project_body" "PROJECT-EDITED"
# User-scope copy (read through the symlink) must be back to the embed
# bytes — no sentinel, original SHA.
user_doc="$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}/${SKILL_MANIFEST_FILE}"
user_body="$(cat "$user_doc")"
assert_not_contains "user copy refreshed from embed" "$user_body" "PROJECT-EDITED"
user_sha="$(sha256_of "$user_doc")"
bundle_sha="$(sha256_of "${REPO_ROOT}/${AGENTS_EMBED_ROOT}/${SKILLS_SUBDIR}/${SKILL_SHIP_DIR}/${SKILL_MANIFEST_FILE}")"
assert_eq "user copy ≡ embed sha256 after refresh" "$user_sha" "$bundle_sha"

# ---------- work-items next-prefix ----------

case_start "stax work-items(no subcommand)"
run_capture "" work-items
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: stax work-items <subcommand>"

case_start "stax work-items <typo>"
run_capture "" work-items frobnicate
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "unknown work-items subcommand: frobnicate"

case_start "stax work-items next-prefix outside a stax project"
PROJ_NP="$(fresh_project)"
cd "$PROJ_NP"
run_capture "" work-items next-prefix
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not a stax project"
assert_contains "hint"       "$RUN_ERR" "stax init"

case_start "stax work-items next-prefix in fresh ${STAX_DIR} (empty)"
PROJ_NP_EMPTY="$(fresh_project)"
seed_project_scaffold "$PROJ_NP_EMPTY"
cd "$PROJ_NP_EMPTY"
run_capture "" work-items next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "first prefix" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "stax work-items next-prefix with default width"
PROJ_NP2="$(fresh_project)"
seed_project_scaffold "$PROJ_NP2"
touch "$PROJ_NP2/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
      "$PROJ_NP2/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-bar.md"
cd "$PROJ_NP2"
run_capture "" work-items next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "max+1 default width" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 4)"

case_start "stax work-items next-prefix honors ${STAX_LOCK_FILE} prefix_width"
PROJ_NP3="$(fresh_project)"
seed_project_scaffold "$PROJ_NP3"
custom_width=7
echo "{\"prefix_width\":${custom_width}}" > "$PROJ_NP3/${STAX_LOCK_PATH}"
touch "$PROJ_NP3/${STAX_DIR}/$(prefix "$custom_width" 41)-foo.md"
cd "$PROJ_NP3"
run_capture "" work-items next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "custom width applied" "$RUN_OUT" "$(prefix "$custom_width" 42)"

case_start "stax work-items next-prefix rejects positional arg"
cd "$(fresh_project)"
run_capture "" work-items next-prefix some/dir
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no arguments"

case_start "stax work-items next-prefix ignores non-matching filenames"
PROJ_NP4="$(fresh_project)"
seed_project_scaffold "$PROJ_NP4"
touch "$PROJ_NP4/${STAX_DIR}/notes.md" \
      "$PROJ_NP4/${STAX_DIR}/README" \
      "$PROJ_NP4/${STAX_DIR}/abc-foo.md" \
      "$PROJ_NP4/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 7)-real.md"
cd "$PROJ_NP4"
run_capture "" work-items next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "non-matching ignored" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 8)"

case_start "stax work-items next-prefix ignores prefixes WIDER than the configured width"
# scanHighestPrefix anchors on `<width digits>-` (same format listPlans uses)
# so a 5-digit-prefixed file at width=4 is invisible — otherwise next-prefix
# would hand out numbers based on files list / lint silently ignore.
PROJ_NP_WIDE="$(fresh_project)"
seed_project_scaffold "$PROJ_NP_WIDE"
touch "$PROJ_NP_WIDE/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-three.md" \
      "$PROJ_NP_WIDE/${STAX_DIR}/00099-extra.md" \
      "$PROJ_NP_WIDE/${STAX_DIR}/00500-bigger.md"
cd "$PROJ_NP_WIDE"
run_capture "" work-items next-prefix
assert_eq "exit 0"                  "$RUN_RC" "0"
assert_eq "wider prefix invisible"  "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 4)"

case_start "stax work-items next-prefix with only lock file (no work-item files)"
PROJ_NP5="$(fresh_project)"
seed_project_scaffold "$PROJ_NP5"
echo "{\"prefix_width\":${DEFAULT_PREFIX_WIDTH}}" > "$PROJ_NP5/${STAX_LOCK_PATH}"
cd "$PROJ_NP5"
run_capture "" work-items next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "lock-only → first prefix" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "stax work-items next-prefix falls back to default width on malformed lock"
PROJ_NP6="$(fresh_project)"
seed_project_scaffold "$PROJ_NP6"
echo '{not json' > "$PROJ_NP6/${STAX_LOCK_PATH}"
cd "$PROJ_NP6"
run_capture "" work-items next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "default width on bad lock" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "stax work-items next-prefix falls back to default width on zero prefix_width"
PROJ_NP7="$(fresh_project)"
seed_project_scaffold "$PROJ_NP7"
echo '{"prefix_width":0}' > "$PROJ_NP7/${STAX_LOCK_PATH}"
cd "$PROJ_NP7"
run_capture "" work-items next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "default width on zero" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "stax work-items next-prefix rolls past width digits"
PROJ_NP8="$(fresh_project)"
seed_project_scaffold "$PROJ_NP8"
# Seed with a prefix that exactly fills DEFAULT_PREFIX_WIDTH (all 9s), so
# incrementing it overflows the digit budget. With width=4 that's 9999;
# bump the seed when the constant changes.
seed_overflow="$(printf '%0*d' "$DEFAULT_PREFIX_WIDTH" 0 | tr '0' '9')"
overflow_next="$((10 ** DEFAULT_PREFIX_WIDTH))"
touch "$PROJ_NP8/${STAX_DIR}/${seed_overflow}-last.md"
cd "$PROJ_NP8"
run_capture "" work-items next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
# fmt.Printf("%0*d", width, n) does not truncate when n already has
# more digits than width — so 9999+1 prints as "10000" at width 4.
assert_eq "overflow keeps counting" "$RUN_OUT" "$overflow_next"

# ---------- work-items list ----------

case_start "stax work-items list (empty ${STAX_DIR})"
PROJ_PL1="$(fresh_project)"
seed_project_scaffold "$PROJ_PL1"
cd "$PROJ_PL1"
run_capture "" work-items list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "no rows on empty" "$RUN_OUT" ""

case_start "stax work-items list outside a stax project"
PROJ_PL2="$(fresh_project)"
cd "$PROJ_PL2"
run_capture "" work-items list
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not a stax project"
assert_contains "hint"       "$RUN_ERR" "stax init"

case_start "stax work-items list emits tab-separated rows sorted by prefix descending (default)"
PROJ_PL3="$(fresh_project)"
seed_project_scaffold "$PROJ_PL3"
write_work_item "$PROJ_PL3/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-bravo.md"   "deprecated" "billing"
write_work_item "$PROJ_PL3/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md"   "valid"      "auth, billing"
write_work_item "$PROJ_PL3/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-charlie.md" "superseded" "auth"
cd "$PROJ_PL3"
run_capture "" work-items list
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-charlie\tsuperseded\tauth\n%s-bravo\tdeprecated\tbilling\n%s-alpha\tvalid\tauth,billing' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"
assert_eq "desc tab-separated rows" "$RUN_OUT" "$expected"

case_start "stax work-items list --order=asc reverses to prefix-ascending"
cd "$PROJ_PL3"
run_capture "" work-items list --order=asc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-alpha\tvalid\tauth,billing\n%s-bravo\tdeprecated\tbilling\n%s-charlie\tsuperseded\tauth' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)")"
assert_eq "asc tab-separated rows" "$RUN_OUT" "$expected"

case_start "stax work-items list --order=desc (explicit default)"
cd "$PROJ_PL3"
run_capture "" work-items list --order=desc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-charlie\tsuperseded\tauth\n%s-bravo\tdeprecated\tbilling\n%s-alpha\tvalid\tauth,billing' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"
assert_eq "explicit desc tab-separated rows" "$RUN_OUT" "$expected"

case_start "stax work-items list --order=bogus rejected"
cd "$PROJ_PL3"
run_capture "" work-items list --order=bogus
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "--order must be"

case_start "stax work-items list --status filters"
cd "$PROJ_PL3"
run_capture "" work-items list --status valid
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "status filter keeps only valid" "$RUN_OUT" \
  "$(printf '%s-alpha\tvalid\tauth,billing' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "stax work-items list --status comma list (desc order)"
cd "$PROJ_PL3"
run_capture "" work-items list --status valid,superseded
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-charlie\tsuperseded\tauth\n%s-alpha\tvalid\tauth,billing' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"
assert_eq "comma status filter (desc)" "$RUN_OUT" "$expected"

case_start "stax work-items list --system OR semantics (desc order)"
cd "$PROJ_PL3"
run_capture "" work-items list --system billing
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-bravo\tdeprecated\tbilling\n%s-alpha\tvalid\tauth,billing' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"
assert_eq "system filter matches any (desc)" "$RUN_OUT" "$expected"

case_start "stax work-items list combined --status and --system"
cd "$PROJ_PL3"
run_capture "" work-items list --status valid --system auth
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "status+system intersection" "$RUN_OUT" \
  "$(printf '%s-alpha\tvalid\tauth,billing' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "stax work-items list warns on malformed frontmatter but keeps siblings"
PROJ_PL4="$(fresh_project)"
seed_project_scaffold "$PROJ_PL4"
broken_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-broken.md"
ok_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-ok.md"
echo "not a work item" > "$PROJ_PL4/${STAX_DIR}/$broken_name"
write_work_item "$PROJ_PL4/${STAX_DIR}" "$ok_name" "valid" "auth"
cd "$PROJ_PL4"
run_capture "" work-items list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "broken skipped, ok kept" "$RUN_OUT" \
  "$(printf '%s\tvalid\tauth' "${ok_name%.md}")"
assert_contains "warning to stderr" "$RUN_ERR" "$broken_name"

case_start "stax work-items list ignores non-matching filenames"
PROJ_PL5="$(fresh_project)"
seed_project_scaffold "$PROJ_PL5"
keep_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-keep.md"
write_work_item "$PROJ_PL5/${STAX_DIR}" "$keep_name" "valid" "auth"
echo "x" > "$PROJ_PL5/${STAX_DIR}/README.md"
echo "x" > "$PROJ_PL5/${STAX_DIR}/123-short.md"
echo "x" > "$PROJ_PL5/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-no-ext"
cd "$PROJ_PL5"
run_capture "" work-items list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "only keep matched" "$RUN_OUT" "$(printf '%s\tvalid\tauth' "${keep_name%.md}")"
[ -z "$RUN_ERR" ] && ok "no spurious warnings" || fail "no spurious warnings" "got: $RUN_ERR"

case_start "stax work-items list rejects positional args"
cd "$(fresh_project)"
run_capture "" work-items list foo
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no positional"

# ---------- work-items list: --system id-aware filter ----------
#
# `--system` matches the kebab `id:` value work items carry in their
# frontmatter `systems:` array. Both sides are id strings — no name
# resolution, no fuzzy match, and `--system` does NOT consult
# `_data_systems.yaml` to validate the requested id (an unknown id
# simply matches zero rows). These cases pin every observable corner
# of the id contract beyond the basic OR semantics covered above.

case_start "stax work-items list --system <kebab-id> matches multi-word system id"
PROJ_PSI1="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI1"
write_work_item "$PROJ_PSI1/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md" "valid" "checkout-service"
write_work_item "$PROJ_PSI1/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-bravo.md" "valid" "payment-audit-log"
cd "$PROJ_PSI1"
run_capture "" work-items list --system checkout-service
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "only checkout-service work item returned" "$RUN_OUT" \
  "$(printf '%s-alpha\tvalid\tcheckout-service' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "stax work-items list --system <unknown-id> returns zero rows silently"
PROJ_PSI2="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI2"
write_work_item "$PROJ_PSI2/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md" "valid" "checkout-service"
cd "$PROJ_PSI2"
run_capture "" work-items list --system never-declared
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "no rows for unknown id" "$RUN_OUT" ""
[ -z "$RUN_ERR" ] && ok "no stderr noise for unknown id" || fail "no stderr noise for unknown id" "got: $RUN_ERR"

case_start "stax work-items list --system <id> doesn't match display name even when formed similarly"
# Plan frontmatter id is `checkout-service`; passing the display name
# `Checkout Service` (with space + capitals) must not match. Pins that
# the filter is a literal id string-compare, not a slugify-and-compare.
PROJ_PSI_DN="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI_DN"
write_work_item "$PROJ_PSI_DN/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md" "valid" "checkout-service"
cd "$PROJ_PSI_DN"
run_capture "" work-items list --system "Checkout Service"
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "display name doesn't match kebab id" "$RUN_OUT" ""

case_start "stax work-items list --system <id1>,<id2> OR semantics via comma list"
PROJ_PSI3="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI3"
write_work_item "$PROJ_PSI3/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-a.md" "valid" "checkout-service"
write_work_item "$PROJ_PSI3/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-b.md" "valid" "payment-audit-log"
write_work_item "$PROJ_PSI3/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-c.md" "valid" "other-system"
cd "$PROJ_PSI3"
run_capture "" work-items list --system checkout-service,payment-audit-log --order=asc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-a\tvalid\tcheckout-service\n%s-b\tvalid\tpayment-audit-log' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)")"
assert_eq "comma-list OR semantics" "$RUN_OUT" "$expected"

case_start "stax work-items list --system <id1> --system <id2> repeated flag = comma list"
cd "$PROJ_PSI3"
run_capture "" work-items list --system checkout-service --system payment-audit-log --order=asc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-a\tvalid\tcheckout-service\n%s-b\tvalid\tpayment-audit-log' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)")"
assert_eq "repeated-flag OR matches comma form" "$RUN_OUT" "$expected"

case_start "stax work-items list --system mixed forms (one comma + one repeat) still OR"
cd "$PROJ_PSI3"
run_capture "" work-items list --system checkout-service,other-system --system payment-audit-log --order=asc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-a\tvalid\tcheckout-service\n%s-b\tvalid\tpayment-audit-log\n%s-c\tvalid\tother-system' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)")"
assert_eq "mixed comma+repeat OR" "$RUN_OUT" "$expected"

case_start "stax work-items list --system <id> matches any element of multi-id systems array"
PROJ_PSI4="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI4"
write_work_item "$PROJ_PSI4/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-a.md" "valid" "checkout-service, payment-audit-log"
write_work_item "$PROJ_PSI4/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-b.md" "valid" "other-system"
cd "$PROJ_PSI4"
run_capture "" work-items list --system payment-audit-log
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "single-id flag matches multi-id row" "$RUN_OUT" \
  "$(printf '%s-a\tvalid\tcheckout-service,payment-audit-log' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "stax work-items list combined --status valid --system <id> intersects both"
PROJ_PSI5="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI5"
write_work_item "$PROJ_PSI5/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-a.md" "valid"      "checkout-service"
write_work_item "$PROJ_PSI5/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-b.md" "superseded" "checkout-service"
write_work_item "$PROJ_PSI5/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-c.md" "valid"      "other-system"
cd "$PROJ_PSI5"
run_capture "" work-items list --status valid --system checkout-service
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "status+id intersection (single match)" "$RUN_OUT" \
  "$(printf '%s-a\tvalid\tcheckout-service' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "stax work-items list --system <id> + --overflow-keywords narrows after id filter"
PROJ_PSI6="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI6"
# Seed enough payment-system work items to cross threshold so overflow engages
# AFTER the --system filter has been applied. Body keyword `retry` then
# narrows further to the one work item whose body mentions retry.
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 5))
for ((i=1; i<=over; i++)); do
  pad="$(printf '%03d' "$i")"
  name="$(prefix "$DEFAULT_PREFIX_WIDTH" "$i")-work-item${pad}.md"
  cat > "$PROJ_PSI6/${STAX_DIR}/$name" <<EOF
---
status: valid
systems: [payment-service]
---
${i} generic body
EOF
done
cat > "$PROJ_PSI6/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 7)-work-item007.md" <<EOF
---
status: valid
systems: [payment-service]
---
this one is about exponential retry backoff
EOF
# An unrelated work item on a different system; same keyword in body — must be
# filtered out by --system before the overflow narrow sees it.
cat > "$PROJ_PSI6/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 99)-unrelated.md" <<EOF
---
status: valid
systems: [unrelated-system]
---
also mentions retry but on a different system
EOF
cd "$PROJ_PSI6"
run_capture "" work-items list --system payment-service --overflow-keywords retry
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "work-item007 in match"      "$RUN_OUT" "work-item007"
assert_not_contains "unrelated filtered out before narrow" "$RUN_OUT" "unrelated"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "exactly one match (id ∩ keyword)" "$n" "1"

case_start "stax work-items list --system <id> below threshold makes --overflow-keywords a no-op"
PROJ_PSI7="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI7"
write_work_item "$PROJ_PSI7/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-a.md" "valid" "checkout-service"
write_work_item "$PROJ_PSI7/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-b.md" "valid" "checkout-service"
cd "$PROJ_PSI7"
# Two work items pass --system; the count (2) is well under the threshold, so
# --overflow-keywords engages no matter what we pass.
run_capture "" work-items list --system checkout-service --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "both rows pass through (threshold not exceeded)" "$n" "2"

case_start "stax work-items list --status + --system + --overflow-keywords narrows status∩system > threshold"
# The only test in the suite that proves --overflow-keywords actually does
# the work when both --status and --system are already applied. Pre-overflow
# count must exceed threshold AFTER status+system filtering; the distractors
# that share status AND system but lack the body keyword can ONLY be
# eliminated by the overflow narrow. Two further distractors carry the
# keyword in body but fail one of status / system — they assert the layer
# ordering (status+system run BEFORE overflow, not after).
PROJ_SSO="$(fresh_project)"
seed_project_scaffold "$PROJ_SSO"
# Threshold+2 work items, all status=valid + system=payment-service, body
# WITHOUT the keyword. Two of them (5, 17) get overwritten below with
# bodies that DO contain "retry".
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 2))
for ((i=1; i<=over; i++)); do
  pad="$(printf '%03d' "$i")"
  name="$(prefix "$DEFAULT_PREFIX_WIDTH" "$i")-work-item${pad}.md"
  cat > "$PROJ_SSO/${STAX_DIR}/$name" <<EOF
---
status: valid
systems: [payment-service]
---
${i} generic body content
EOF
done
for n in 5 17; do
  pad="$(printf '%03d' "$n")"
  cat > "$PROJ_SSO/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" "$n")-work-item${pad}.md" <<EOF
---
status: valid
systems: [payment-service]
---
work item ${n} covers exponential retry backoff
EOF
done
# Cross-filter distractors: each carries "retry" in body but fails one
# of --status (deprecated) or --system (other-service). Must be dropped
# BEFORE the overflow narrow ever runs.
cat > "$PROJ_SSO/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 98)-wrong-status.md" <<EOF
---
status: deprecated
systems: [payment-service]
---
deprecated work item that mentions retry
EOF
cat > "$PROJ_SSO/${STAX_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 99)-wrong-system.md" <<EOF
---
status: valid
systems: [other-service]
---
other-service work item that mentions retry
EOF
cd "$PROJ_SSO"
run_capture "" work-items list --status valid --system payment-service --overflow-keywords retry
assert_eq           "exit 0"                                $RUN_RC "0"
assert_contains     "work-item005 in match"                      "$RUN_OUT" "work-item005"
assert_contains     "work-item017 in match"                      "$RUN_OUT" "work-item017"
assert_not_contains "wrong-status filtered by --status filter" "$RUN_OUT" "wrong-status"
assert_not_contains "wrong-system filtered by --system filter" "$RUN_OUT" "wrong-system"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "exactly two matchers survive (status ∩ system ∩ keyword)" "$n" "2"

# ---------- work-items list: --overflow-keywords + threshold behavior ----------
#
# Contract:
#   - When the post-(--status/--system)-filter row count ≤ threshold,
#     --overflow-keywords is a no-op (caller pays nothing for declaring
#     an unused narrow).
#   - When the count > threshold AND ≥1 row's body matches ≥1 keyword
#     regex (case-insensitive OR), only matched rows are returned.
#   - When the count > threshold AND no row matches, the top-threshold
#     rows in the current sort order are returned as a fallback.
#   - Keywords are case-insensitive and apply to the body only —
#     frontmatter (title, status, systems, etc.) never matches.
#
# These cases pin every observable corner. Threshold is defined in
# constants.go as planListOverflowThreshold; the e2e mirror is
# ${WORK_ITEMS_LIST_OVERFLOW_THRESHOLD}.

case_start "stax work-items list with exactly threshold rows ignores --overflow-keywords"
PROJ_OK1="$(fresh_project)"
seed_project_scaffold "$PROJ_OK1"
seed_many_plans "$PROJ_OK1/${STAX_DIR}" "${WORK_ITEMS_LIST_OVERFLOW_THRESHOLD}" "payment retry"
cd "$PROJ_OK1"
run_capture "" work-items list --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
ok_count="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "all ${WORK_ITEMS_LIST_OVERFLOW_THRESHOLD} rows returned (no narrow at threshold)" \
  "$ok_count" "${WORK_ITEMS_LIST_OVERFLOW_THRESHOLD}"

case_start "stax work-items list with threshold+1 rows + matching keyword narrows to matches"
PROJ_OK2="$(fresh_project)"
seed_project_scaffold "$PROJ_OK2"
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK2/${STAX_DIR}" "$over" "generic body"
# Overwrite three specific work items' bodies to contain the keyword.
write_work_item_body "$PROJ_OK2/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 5)-work-item005.md"  "the Payment Service handles charges"
write_work_item_body "$PROJ_OK2/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 10)-work-item010.md" "PAYMENT pipeline upgrade"
write_work_item_body "$PROJ_OK2/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 15)-work-item015.md" "deprecated payment flow"
cd "$PROJ_OK2"
run_capture "" work-items list --overflow-keywords payment
assert_eq "exit 0" "$RUN_RC" "0"
match_count="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "3 matches returned" "$match_count" "3"
assert_contains "work-item005 in matches"  "$RUN_OUT" "work-item005"
assert_contains "work-item010 in matches"  "$RUN_OUT" "work-item010"
assert_contains "work-item015 in matches"  "$RUN_OUT" "work-item015"

case_start "stax work-items list overflow + no-match falls back to top-threshold rows"
PROJ_OK3="$(fresh_project)"
seed_project_scaffold "$PROJ_OK3"
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 5))
seed_many_plans "$PROJ_OK3/${STAX_DIR}" "$over" "non-matching body"
cd "$PROJ_OK3"
run_capture "" work-items list --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
fb_count="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "fallback returns exactly threshold rows" "$fb_count" "${WORK_ITEMS_LIST_OVERFLOW_THRESHOLD}"
# Default sort is desc → fallback keeps the highest prefixes (newest).
assert_contains "newest work item in fallback"  "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" "$over")-work-item"
assert_not_contains "oldest work item dropped"  "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-work-item001"

case_start "stax work-items list overflow without --overflow-keywords returns all rows (no truncation)"
PROJ_OK4="$(fresh_project)"
seed_project_scaffold "$PROJ_OK4"
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 3))
seed_many_plans "$PROJ_OK4/${STAX_DIR}" "$over" "anything"
cd "$PROJ_OK4"
run_capture "" work-items list
assert_eq "exit 0" "$RUN_RC" "0"
all_count="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "all rows returned (caller opted out of narrowing)" "$all_count" "$over"

case_start "stax work-items list overflow + multi-keyword OR semantics"
PROJ_OK5="$(fresh_project)"
seed_project_scaffold "$PROJ_OK5"
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK5/${STAX_DIR}" "$over" "irrelevant"
write_work_item_body "$PROJ_OK5/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-work-item003.md" "talks about checkout"
write_work_item_body "$PROJ_OK5/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 7)-work-item007.md" "discusses inventory"
write_work_item_body "$PROJ_OK5/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 9)-work-item009.md" "covers shipping logistics"
cd "$PROJ_OK5"
run_capture "" work-items list --overflow-keywords checkout,inventory
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "OR matches both terms" "$n" "2"
assert_contains "work-item003 (checkout)"  "$RUN_OUT" "work-item003"
assert_contains "work-item007 (inventory)" "$RUN_OUT" "work-item007"
assert_not_contains "work-item009 not matched" "$RUN_OUT" "work-item009"

case_start "stax work-items list overflow + substring match is literal (regex chars not special)"
PROJ_OK6="$(fresh_project)"
seed_project_scaffold "$PROJ_OK6"
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK6/${STAX_DIR}" "$over" "generic"
write_work_item_body "$PROJ_OK6/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 4)-work-item004.md" "auth-v1 service"
write_work_item_body "$PROJ_OK6/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 8)-work-item008.md" "auth-v2 service"
write_work_item_body "$PROJ_OK6/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 12)-work-item012.md" "auth0 integration"
cd "$PROJ_OK6"
# Plain substring 'auth-v' matches work-item004 + work-item008 (both contain that
# hyphen) but NOT work-item012 (no hyphen). Same behavior with literal regex
# special chars: '.' is a dot, not "any char".
run_capture "" work-items list --overflow-keywords 'auth-v'
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "substring matches exactly the two -v rows" "$n" "2"
assert_contains "work-item004"  "$RUN_OUT" "work-item004"
assert_contains "work-item008"  "$RUN_OUT" "work-item008"
assert_not_contains "work-item012 not matched" "$RUN_OUT" "work-item012"
# Confirm regex special chars are literal: a dot in the body must not be
# matched by anything other than a literal dot in the keyword.
write_work_item_body "$PROJ_OK6/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 17)-work-item017.md" "v1.2.3 release"
run_capture "" work-items list --overflow-keywords 'v1.2'
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "v1.2 (literal dot) hits work-item017" "$RUN_OUT" "work-item017"

case_start "stax work-items list overflow + frontmatter terms do NOT match (body-only)"
PROJ_OK7="$(fresh_project)"
seed_project_scaffold "$PROJ_OK7"
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK7/${STAX_DIR}" "$over" "body content"
cd "$PROJ_OK7"
# "auth" is in every work item's frontmatter `systems:` (the kebab id) but
# never in body. Keyword search is body-only → no matches → top-threshold
# fallback. The capitalized `Auth` keyword would not match either; the
# real point is that frontmatter scalars (whatever their case) never feed
# the body-only narrow.
run_capture "" work-items list --overflow-keywords Auth
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "frontmatter doesn't match → fallback to top-threshold" "$n" "${WORK_ITEMS_LIST_OVERFLOW_THRESHOLD}"

case_start "stax work-items list overflow + --status filter narrows below threshold first"
PROJ_OK8="$(fresh_project)"
seed_project_scaffold "$PROJ_OK8"
# Seed 25 work items, mark 3 as "deprecated" — --status filter will reduce
# the post-status set to 3, far below threshold, so overflow-keywords
# never engages.
seed_many_plans "$PROJ_OK8/${STAX_DIR}" 25 "body"
# Flip three work items to deprecated.
for n in 5 10 15; do
  pad="$(printf '%03d' "$n")"
  name="$(prefix "$DEFAULT_PREFIX_WIDTH" "$n")-work-item${pad}.md"
  sed -i.bak -e 's/^status: valid$/status: deprecated/' "$PROJ_OK8/${STAX_DIR}/$name"
  rm -f "$PROJ_OK8/${STAX_DIR}/$name.bak"
done
cd "$PROJ_OK8"
run_capture "" work-items list --status deprecated --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "3 deprecated rows pass through ungrep" "$n" "3"

case_start "stax work-items list --order=asc preserved through overflow narrow"
PROJ_OK9="$(fresh_project)"
seed_project_scaffold "$PROJ_OK9"
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK9/${STAX_DIR}" "$over" "irrelevant"
# Seed two matches, far apart in the sort.
write_work_item_body "$PROJ_OK9/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-work-item002.md"   "payment thing"
write_work_item_body "$PROJ_OK9/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 18)-work-item018.md"  "payment thing"
cd "$PROJ_OK9"
run_capture "" work-items list --order=asc --overflow-keywords payment
assert_eq "exit 0" "$RUN_RC" "0"
first="$(printf '%s\n' "$RUN_OUT" | head -n1 | awk -F'\t' '{print $1}')"
last="$(printf '%s\n' "$RUN_OUT" | tail -n1 | awk -F'\t' '{print $1}')"
assert_contains "asc: work-item002 first"  "$first" "work-item002"
assert_contains "asc: work-item018 last"   "$last" "work-item018"

case_start "stax work-items list overflow + fallback respects --order=asc"
PROJ_OK10="$(fresh_project)"
seed_project_scaffold "$PROJ_OK10"
over=$((WORK_ITEMS_LIST_OVERFLOW_THRESHOLD + 3))
seed_many_plans "$PROJ_OK10/${STAX_DIR}" "$over" "irrelevant"
cd "$PROJ_OK10"
run_capture "" work-items list --order=asc --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
# asc fallback returns rows[0..threshold) of asc-sorted list = oldest 20.
first="$(printf '%s\n' "$RUN_OUT" | head -n1 | awk -F'\t' '{print $1}')"
assert_contains "asc fallback starts at work-item001"  "$first" "work-item001"
assert_not_contains "asc fallback drops newest"   "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" "$over")-work-item"

case_start "stax work-items list overflow + match count above threshold returned in full"
PROJ_OK12="$(fresh_project)"
seed_project_scaffold "$PROJ_OK12"
# 25 work items, ALL match the keyword. The narrow returns 25 (matches are
# not re-truncated — the threshold restricts entry to the narrow, not the
# output size).
seed_many_plans "$PROJ_OK12/${STAX_DIR}" 25 "matches every work item"
cd "$PROJ_OK12"
run_capture "" work-items list --overflow-keywords matches
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "all-match returns all 25" "$n" "25"

# ---------- work-items lint ----------

case_start "stax work-items lint outside a stax project"
PROJ_LN0="$(fresh_project)"
cd "$PROJ_LN0"
run_capture "" work-items lint
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not a stax project"
assert_contains "hint"       "$RUN_ERR" "stax init"

case_start "stax work-items lint happy path"
PROJ_LN1="$(fresh_project)"
seed_project_scaffold "$PROJ_LN1"
write_registry "$PROJ_LN1/${STAX_DIR}" "Auth Service"
plan1_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
write_full_work_item "$PROJ_LN1/${STAX_DIR}" "$plan1_name" "valid" "auth-service" "Auth Service"
cd "$PROJ_LN1"
run_capture "" work-items lint
assert_eq "exit 0"               "$RUN_RC" "0"
assert_contains "ok line"        "$RUN_OUT" "$plan1_name: ok"
assert_contains "summary 1 ok"   "$RUN_ERR" "1 ok, 0 failed"

case_start "stax work-items lint flags bad filename"
PROJ_LN2="$(fresh_project)"
seed_project_scaffold "$PROJ_LN2"
write_registry "$PROJ_LN2/${STAX_DIR}" "Auth Service"
write_full_work_item "$PROJ_LN2/${STAX_DIR}" "BAD-NAME.md" "valid" "auth-service" "Auth Service"
cd "$PROJ_LN2"
run_capture "" work-items lint
assert_eq "exit 1"               "$RUN_RC" "1"
assert_contains "filename finding" "$RUN_OUT" "does not match <prefix>-<slug>.md"

case_start "stax work-items lint flags missing frontmatter"
PROJ_LN3="$(fresh_project)"
seed_project_scaffold "$PROJ_LN3"
write_registry "$PROJ_LN3/${STAX_DIR}" "Auth Service"
broken_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-broken.md"
echo "just body, no frontmatter" > "$PROJ_LN3/${STAX_DIR}/$broken_name"
cd "$PROJ_LN3"
run_capture "" work-items lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "frontmatter finding" "$RUN_OUT" "missing YAML frontmatter"

case_start "stax work-items lint flags bad status"
PROJ_LN4="$(fresh_project)"
seed_project_scaffold "$PROJ_LN4"
write_registry "$PROJ_LN4/${STAX_DIR}" "Auth Service"
write_full_work_item "$PROJ_LN4/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "bogus" "auth-service" "Auth Service"
cd "$PROJ_LN4"
run_capture "" work-items lint
assert_eq "exit 1"           "$RUN_RC" "1"
assert_contains "bad status" "$RUN_OUT" "status \"bogus\" is not one of"

case_start "stax work-items lint flags system not in registry"
PROJ_LN5="$(fresh_project)"
seed_project_scaffold "$PROJ_LN5"
write_registry "$PROJ_LN5/${STAX_DIR}" "Auth Service"
write_full_work_item "$PROJ_LN5/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "valid" "ghost-service" "Ghost Service"
cd "$PROJ_LN5"
run_capture "" work-items lint
assert_eq "exit 1"                "$RUN_RC" "1"
assert_contains "system finding"  "$RUN_OUT" "declared system \"ghost-service\" is not in"

case_start "stax work-items lint flags dangling supersedes"
PROJ_LN6="$(fresh_project)"
seed_project_scaffold "$PROJ_LN6"
write_registry "$PROJ_LN6/${STAX_DIR}" "Auth Service"
super_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN6/${STAX_DIR}/$super_name" <<EOF
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
EOF
cd "$PROJ_LN6"
run_capture "" work-items lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "supersedes finding" "$RUN_OUT" "supersedes \"00099-nope\""

case_start "stax work-items lint flags EARS-systems mismatch"
PROJ_LN7="$(fresh_project)"
seed_project_scaffold "$PROJ_LN7"
write_registry "$PROJ_LN7/${STAX_DIR}" "Auth Service,Billing Service"
# Declares Auth but task names Billing — both diff directions fire.
write_full_work_item "$PROJ_LN7/${STAX_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "valid" "auth-service" "Billing Service"
cd "$PROJ_LN7"
run_capture "" work-items lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "EARS-not-in-systems"    "$RUN_OUT" "EARS tasks name systems not in \`systems:\`"
assert_contains "systems-not-in-tasks"   "$RUN_OUT" "\`systems:\` declares systems not used in any EARS task"

case_start "stax work-items lint rejects positional arg"
cd "$(fresh_project)"
run_capture "" work-items lint somearg
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no arguments"

case_start "stax work-items lint flags missing title"
PROJ_LN_TT="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_TT"
write_registry "$PROJ_LN_TT/${STAX_DIR}" "Auth Service"
no_title_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_TT/${STAX_DIR}/$no_title_name" <<EOF
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
EOF
cd "$PROJ_LN_TT"
run_capture "" work-items lint
assert_eq "exit 1"               "$RUN_RC" "1"
assert_contains "title finding"  "$RUN_OUT" "missing required \`title:\`"

case_start "stax work-items lint flags missing created"
PROJ_LN_CR="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_CR"
write_registry "$PROJ_LN_CR/${STAX_DIR}" "Auth Service"
no_created_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_CR/${STAX_DIR}/$no_created_name" <<EOF
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
EOF
cd "$PROJ_LN_CR"
run_capture "" work-items lint
assert_eq "exit 1"                 "$RUN_RC" "1"
assert_contains "created finding"  "$RUN_OUT" "missing required \`created:\`"

case_start "stax work-items lint flags malformed created"
PROJ_LN_CD="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_CD"
write_registry "$PROJ_LN_CD/${STAX_DIR}" "Auth Service"
bad_created_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_CD/${STAX_DIR}/$bad_created_name" <<EOF
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
EOF
cd "$PROJ_LN_CD"
run_capture "" work-items lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "format finding"    "$RUN_OUT" "is not an ISO 8601 UTC timestamp"

case_start "stax work-items lint flags date-only created (regression for YYYY-MM-DD)"
PROJ_LN_DO="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_DO"
write_registry "$PROJ_LN_DO/${STAX_DIR}" "Auth Service"
date_only_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_DO/${STAX_DIR}/$date_only_name" <<EOF
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
EOF
cd "$PROJ_LN_DO"
run_capture "" work-items lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "date-only rejected"     "$RUN_OUT" "\"2026-05-23\" is not an ISO 8601 UTC timestamp"

case_start "stax work-items lint flags title-not-first"
PROJ_LN_TO="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_TO"
write_registry "$PROJ_LN_TO/${STAX_DIR}" "Auth Service"
order_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_TO/${STAX_DIR}/$order_name" <<EOF
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
EOF
cd "$PROJ_LN_TO"
run_capture "" work-items lint
assert_eq "exit 1"               "$RUN_RC" "1"
assert_contains "order finding"  "$RUN_OUT" "must be the first frontmatter field"

case_start "stax work-items lint flags filename ≠ slugify(title)"
PROJ_LN_FT="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_FT"
write_registry "$PROJ_LN_FT/${STAX_DIR}" "Auth Service"
mismatch_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
write_full_work_item "$PROJ_LN_FT/${STAX_DIR}" "$mismatch_name" "valid" "auth-service" "Auth Service"
# Overwrite title with one that slugifies to "something-else".
sed -i.bak -e 's/^title: foo/title: Something Else/' "$PROJ_LN_FT/${STAX_DIR}/$mismatch_name"
rm -f "$PROJ_LN_FT/${STAX_DIR}/$mismatch_name.bak"
cd "$PROJ_LN_FT"
run_capture "" work-items lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "filename↔title"    "$RUN_OUT" "does not match slugify(title)"

# ---------- work-items lint: id-aware registry + EARS-name resolution ----------
#
# After the registry switched to carrying explicit kebab `id:` values
# (parsed by parseRegistry into id↔name maps), the linter performs two
# distinct lookups against `_data_systems.yaml`:
#
#   1) Every entry in frontmatter `systems:` must be a known `id:` —
#      checked against registry.byID. A work item that left a display name in
#      `systems:` (a common migration slip) fails here.
#   2) Every EARS subject in body text (a display name like "Auth
#      Service") must resolve to an id via registry.byName; the resolved
#      id set must equal the declared `systems:` id set exactly.
#
# Partial registry entries (missing `id:` OR missing `name:`) are dropped
# silently by parseRegistry — the per-file lint surfaces them at the
# point a work item tries to reference the partially defined entry.

case_start "lint passes: id frontmatter + display-name EARS subject resolves cleanly"
PROJ_ID_HP="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_HP"
write_registry "$PROJ_ID_HP/${STAX_DIR}" "Auth Service"
hp_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
write_full_work_item "$PROJ_ID_HP/${STAX_DIR}" "$hp_name" "valid" "auth-service" "Auth Service"
cd "$PROJ_ID_HP"
run_capture "" work-items lint
assert_eq "exit 0"        "$RUN_RC" "0"
assert_contains "ok line" "$RUN_OUT" "$hp_name: ok"

case_start "lint flags frontmatter that uses a display name where an id belongs"
# A typical migration slip: author left `Auth Service` (the display name)
# in `systems:` instead of switching to the kebab id. Lint must surface
# it as "declared system not in registry".
PROJ_ID_BAD="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_BAD"
write_registry "$PROJ_ID_BAD/${STAX_DIR}" "Auth Service"
bad_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_BAD/${STAX_DIR}/$bad_name" <<EOF
---
title: foo
status: valid
systems: [Auth Service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
EOF
cd "$PROJ_ID_BAD"
run_capture "" work-items lint
assert_eq "exit 1"                    "$RUN_RC" "1"
assert_contains "id-not-in-registry"  "$RUN_OUT" "declared system \"Auth Service\" is not in"

case_start "lint flags EARS subject whose display name isn't in registry"
# Registry has only Auth Service. Frontmatter declares its id cleanly,
# but the body's EARS task names a system that has no registry entry —
# the new name→id resolution surfaces "EARS subject is not in <registry>".
PROJ_ID_ES="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_ES"
write_registry "$PROJ_ID_ES/${STAX_DIR}" "Auth Service"
es_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_ES/${STAX_DIR}/$es_name" <<EOF
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
EOF
cd "$PROJ_ID_ES"
run_capture "" work-items lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "unknown-subject"        "$RUN_OUT" "EARS subject \"Phantom Service\" is not in"

case_start "lint passes on multi-system work item with all subjects resolved cleanly"
# Two registered systems, both declared in frontmatter by id and both
# named in the body. The name→id translation collapses to the same id
# set on both sides; no findings should fire.
PROJ_ID_MS="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_MS"
write_registry "$PROJ_ID_MS/${STAX_DIR}" "Auth Service,Billing Service"
ms_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_MS/${STAX_DIR}/$ms_name" <<EOF
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
EOF
cd "$PROJ_ID_MS"
run_capture "" work-items lint
assert_eq "exit 0"        "$RUN_RC" "0"
assert_contains "ok line" "$RUN_OUT" "$ms_name: ok"

case_start "lint flags partial registry entry (id only): work item can't reference it"
# parseRegistry drops entries with no `name:`. Referencing the dropped
# id from frontmatter therefore surfaces an "id not in registry" finding.
PROJ_ID_PI="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_PI"
cat > "$PROJ_ID_PI/${STAX_DIR}/${STAX_SYSTEMS_FILE}" <<EOF
systems:
  - id: auth-service
    name: Auth Service
    brief: handles auth
  - id: partial-thing
    brief: missing name field
EOF
pi_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_PI/${STAX_DIR}/$pi_name" <<EOF
---
title: foo
status: valid
systems: [partial-thing]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
EOF
cd "$PROJ_ID_PI"
run_capture "" work-items lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "partial entry dropped"  "$RUN_OUT" "declared system \"partial-thing\" is not in"

case_start "lint flags partial registry entry (name only): EARS subject can't resolve"
# Mirror image of the previous case: an entry with `name:` but no `id:`
# is dropped, so body subject "Lone Name" has no id to resolve to.
PROJ_ID_PN="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_PN"
cat > "$PROJ_ID_PN/${STAX_DIR}/${STAX_SYSTEMS_FILE}" <<EOF
systems:
  - id: auth-service
    name: Auth Service
    brief: handles auth
  - name: Lone Name
    brief: missing id field
EOF
pn_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_PN/${STAX_DIR}/$pn_name" <<EOF
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
- [ ] The Lone Name shall do.
EOF
cd "$PROJ_ID_PN"
run_capture "" work-items lint
assert_eq "exit 1"                        "$RUN_RC" "1"
assert_contains "name-only entry dropped" "$RUN_OUT" "EARS subject \"Lone Name\" is not in"

case_start "lint flags display-name-in-systems AND subject-id-not-resolved together"
# Author put a display name in `systems:` AND the body subject happens to
# match an existing registry name. The id-membership check fails on the
# frontmatter; the EARS check ALSO fires because subject→id resolves to
# "auth-service" which isn't in the declared set ["Auth Service"].
PROJ_ID_BOTH="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_BOTH"
write_registry "$PROJ_ID_BOTH/${STAX_DIR}" "Auth Service"
both_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_BOTH/${STAX_DIR}/$both_name" <<EOF
---
title: foo
status: valid
systems: [Auth Service]
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
EOF
cd "$PROJ_ID_BOTH"
run_capture "" work-items lint
assert_eq "exit 1"                              "$RUN_RC" "1"
assert_contains "frontmatter id rejected"       "$RUN_OUT" "declared system \"Auth Service\" is not in"
assert_contains "EARS subject not declared"     "$RUN_OUT" "EARS tasks name systems not in \`systems:\`"
assert_contains "frontmatter id orphaned"       "$RUN_OUT" "\`systems:\` declares systems not used in any EARS task"

# ---------- relation back-links: supersedes/superseded_by + extends/extended_by ----------
#
# `stax work-items lint` enforces, for each forward/back pair:
#   1) every slug in the array resolves to a sibling work item
#   2) a work item cannot reference itself in any of these arrays
#   3) the forward link and back link are symmetric across work items
#
# These cases pin every observable corner of that contract. The
# write_relation_work_item helper composes a lint-passing baseline (title,
# status, systems, EARS body, created) and splices in whatever relation
# line(s) the case wants right before `created:`.

# write_relation_work_item <dir> <name> <status> <relation-lines>
# <relation-lines> may be empty or contain one or more newline-separated
# frontmatter keys (e.g. `supersedes: [00002-bar]`).
write_relation_work_item() {
  local dir="$1" fname="$2" status="$3" relation="$4"
  local slug="${fname#*-}"
  slug="${slug%.md}"
  : "${slug:=foo}"
  cat > "${dir}/${fname}" <<EOF
---
title: ${slug}
status: ${status}
systems: [auth-service]
${relation}
created: 2026-05-23T14:30:00Z
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
EOF
}

# Slugs reused across the relation cases — declared once so renames stay local.
rel_a="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha"
rel_b="$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-bravo"
rel_c="$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-charlie"
dangling="$(prefix "$DEFAULT_PREFIX_WIDTH" 99)-nope"

case_start "lint passes: supersedes/superseded_by symmetric pair"
PROJ_REL_SH="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_SH"
write_registry "$PROJ_REL_SH/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_SH/${STAX_DIR}" "${rel_b}.md" "valid"      "supersedes: [${rel_a}]"
write_relation_work_item "$PROJ_REL_SH/${STAX_DIR}" "${rel_a}.md" "superseded" "superseded_by: [${rel_b}]"
cd "$PROJ_REL_SH"
run_capture "" work-items lint
assert_eq "lint exit 0 on symmetric supersedes pair" "$RUN_RC" "0"

case_start "lint passes: extends/extended_by symmetric pair"
PROJ_REL_EH="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_EH"
write_registry "$PROJ_REL_EH/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_EH/${STAX_DIR}" "${rel_b}.md" "valid" "extends: [${rel_a}]"
write_relation_work_item "$PROJ_REL_EH/${STAX_DIR}" "${rel_a}.md" "valid" "extended_by: [${rel_b}]"
cd "$PROJ_REL_EH"
run_capture "" work-items lint
assert_eq "lint exit 0 on symmetric extends pair" "$RUN_RC" "0"

case_start "lint passes: both pairs present and symmetric on the same predecessor"
# A is superseded by B AND extended by C (a degenerate corner case — once
# something is superseded its 'extended_by' is academic — but lint
# doesn't forbid the combination, and the user might have it during a
# multi-step migration).
PROJ_REL_MIX="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_MIX"
write_registry "$PROJ_REL_MIX/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_MIX/${STAX_DIR}" "${rel_b}.md" "valid"      "supersedes: [${rel_a}]"
write_relation_work_item "$PROJ_REL_MIX/${STAX_DIR}" "${rel_c}.md" "valid"      "extends: [${rel_a}]"
write_relation_work_item "$PROJ_REL_MIX/${STAX_DIR}" "${rel_a}.md" "superseded" "$(printf 'superseded_by: [%s]\nextended_by: [%s]' "$rel_b" "$rel_c")"
cd "$PROJ_REL_MIX"
run_capture "" work-items lint
assert_eq "lint exit 0 with mixed-relation predecessor" "$RUN_RC" "0"

case_start "lint flags dangling supersedes slug"
PROJ_REL_DSF="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_DSF"
write_registry "$PROJ_REL_DSF/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_DSF/${STAX_DIR}" "${rel_a}.md" "valid" "supersedes: [${dangling}]"
cd "$PROJ_REL_DSF"
run_capture "" work-items lint
assert_eq "exit 1"                          "$RUN_RC" "1"
assert_contains "dangling supersedes"       "$RUN_OUT" "supersedes \"${dangling}\""

case_start "lint flags dangling superseded_by slug"
PROJ_REL_DSB="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_DSB"
write_registry "$PROJ_REL_DSB/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_DSB/${STAX_DIR}" "${rel_a}.md" "superseded" "superseded_by: [${dangling}]"
cd "$PROJ_REL_DSB"
run_capture "" work-items lint
assert_eq "exit 1"                              "$RUN_RC" "1"
assert_contains "dangling superseded_by"        "$RUN_OUT" "superseded_by \"${dangling}\""

case_start "lint flags dangling extends slug"
PROJ_REL_DEF="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_DEF"
write_registry "$PROJ_REL_DEF/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_DEF/${STAX_DIR}" "${rel_a}.md" "valid" "extends: [${dangling}]"
cd "$PROJ_REL_DEF"
run_capture "" work-items lint
assert_eq "exit 1"                        "$RUN_RC" "1"
assert_contains "dangling extends"        "$RUN_OUT" "extends \"${dangling}\""

case_start "lint flags dangling extended_by slug"
PROJ_REL_DEB="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_DEB"
write_registry "$PROJ_REL_DEB/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_DEB/${STAX_DIR}" "${rel_a}.md" "valid" "extended_by: [${dangling}]"
cd "$PROJ_REL_DEB"
run_capture "" work-items lint
assert_eq "exit 1"                            "$RUN_RC" "1"
assert_contains "dangling extended_by"        "$RUN_OUT" "extended_by \"${dangling}\""

case_start "lint flags self-supersedes"
PROJ_REL_SS="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_SS"
write_registry "$PROJ_REL_SS/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_SS/${STAX_DIR}" "${rel_a}.md" "valid" "supersedes: [${rel_a}]"
cd "$PROJ_REL_SS"
run_capture "" work-items lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "self-supersedes"        "$RUN_OUT" "supersedes cannot reference the work item itself"

case_start "lint flags self-extends"
PROJ_REL_SE="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_SE"
write_registry "$PROJ_REL_SE/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_SE/${STAX_DIR}" "${rel_a}.md" "valid" "extends: [${rel_a}]"
cd "$PROJ_REL_SE"
run_capture "" work-items lint
assert_eq "exit 1"                    "$RUN_RC" "1"
assert_contains "self-extends"        "$RUN_OUT" "extends cannot reference the work item itself"

case_start "lint flags asymmetric supersedes (forward present, back missing)"
PROJ_REL_AS1="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_AS1"
write_registry "$PROJ_REL_AS1/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_AS1/${STAX_DIR}" "${rel_b}.md" "valid" "supersedes: [${rel_a}]"
write_relation_work_item "$PROJ_REL_AS1/${STAX_DIR}" "${rel_a}.md" "superseded" ""
cd "$PROJ_REL_AS1"
run_capture "" work-items lint
assert_eq "exit 1"                                     "$RUN_RC" "1"
assert_contains "missing superseded_by back-link"      "$RUN_OUT" "does not list this work item in its \`superseded_by:\` array"

case_start "lint flags asymmetric supersedes (back present, forward missing)"
PROJ_REL_AS2="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_AS2"
write_registry "$PROJ_REL_AS2/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_AS2/${STAX_DIR}" "${rel_a}.md" "superseded" "superseded_by: [${rel_b}]"
write_relation_work_item "$PROJ_REL_AS2/${STAX_DIR}" "${rel_b}.md" "valid" ""
cd "$PROJ_REL_AS2"
run_capture "" work-items lint
assert_eq "exit 1"                                "$RUN_RC" "1"
assert_contains "missing supersedes back-link"    "$RUN_OUT" "does not list this work item in its \`supersedes:\` array"

case_start "lint flags asymmetric extends (forward present, back missing)"
PROJ_REL_AE1="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_AE1"
write_registry "$PROJ_REL_AE1/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_AE1/${STAX_DIR}" "${rel_b}.md" "valid" "extends: [${rel_a}]"
write_relation_work_item "$PROJ_REL_AE1/${STAX_DIR}" "${rel_a}.md" "valid" ""
cd "$PROJ_REL_AE1"
run_capture "" work-items lint
assert_eq "exit 1"                                  "$RUN_RC" "1"
assert_contains "missing extended_by back-link"     "$RUN_OUT" "does not list this work item in its \`extended_by:\` array"

case_start "lint flags asymmetric extends (back present, forward missing)"
PROJ_REL_AE2="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_AE2"
write_registry "$PROJ_REL_AE2/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_AE2/${STAX_DIR}" "${rel_a}.md" "valid" "extended_by: [${rel_b}]"
write_relation_work_item "$PROJ_REL_AE2/${STAX_DIR}" "${rel_b}.md" "valid" ""
cd "$PROJ_REL_AE2"
run_capture "" work-items lint
assert_eq "exit 1"                              "$RUN_RC" "1"
assert_contains "missing extends back-link"     "$RUN_OUT" "does not list this work item in its \`extends:\` array"

case_start "lint passes: multi-element extends with all back-links present"
PROJ_REL_MA="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_MA"
write_registry "$PROJ_REL_MA/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_MA/${STAX_DIR}" "${rel_c}.md" "valid" "extends: [${rel_a}, ${rel_b}]"
write_relation_work_item "$PROJ_REL_MA/${STAX_DIR}" "${rel_a}.md" "valid" "extended_by: [${rel_c}]"
write_relation_work_item "$PROJ_REL_MA/${STAX_DIR}" "${rel_b}.md" "valid" "extended_by: [${rel_c}]"
cd "$PROJ_REL_MA"
run_capture "" work-items lint
assert_eq "lint exit 0 multi-element symmetric" "$RUN_RC" "0"

case_start "lint flags only the asymmetric pair in a multi-element extends"
# C extends [A, B]. A has the back link; B does not. Lint must catch the
# B side without false-flagging A.
PROJ_REL_PA="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_PA"
write_registry "$PROJ_REL_PA/${STAX_DIR}" "Auth Service"
write_relation_work_item "$PROJ_REL_PA/${STAX_DIR}" "${rel_c}.md" "valid" "extends: [${rel_a}, ${rel_b}]"
write_relation_work_item "$PROJ_REL_PA/${STAX_DIR}" "${rel_a}.md" "valid" "extended_by: [${rel_c}]"
write_relation_work_item "$PROJ_REL_PA/${STAX_DIR}" "${rel_b}.md" "valid" ""
cd "$PROJ_REL_PA"
run_capture "" work-items lint
assert_eq "exit 1"                                  "$RUN_RC" "1"
assert_contains "asymmetric side flagged"           "$RUN_OUT" "extends \"${rel_b}\" but \"${rel_b}\" does not list this work item in its \`extended_by:\` array"
assert_not_contains "symmetric side not flagged"    "$RUN_OUT" "extends \"${rel_a}\" but \"${rel_a}\" does not list"

# ---------- work-items slugify ----------

case_start "stax work-items slugify basic title"
run_capture "" work-items slugify "Hello World"
assert_eq "exit 0"            "$RUN_RC" "0"
assert_eq "slug printed"      "$RUN_OUT" "hello-world"

case_start "stax work-items slugify collapses runs of non-alnum"
run_capture "" work-items slugify "  Foo // Bar  "
assert_eq "exit 0"          "$RUN_RC" "0"
assert_eq "collapsed slug"  "$RUN_OUT" "foo-bar"

case_start "stax work-items slugify lowercases ASCII"
run_capture "" work-items slugify "ALL CAPS"
assert_eq "exit 0"        "$RUN_RC" "0"
assert_eq "lowered slug"  "$RUN_OUT" "all-caps"

case_start "stax work-items slugify rejects missing arg"
run_capture "" work-items slugify
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "exactly one positional"

case_start "stax work-items slugify rejects multiple args"
run_capture "" work-items slugify "foo" "bar"
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "exactly one positional"

case_start "stax work-items slugify rejects unsluggable title"
run_capture "" work-items slugify "!!!"
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "no slug-able characters"

case_start "stax work-items slugify accepts pure numerics"
run_capture "" work-items slugify "123"
assert_eq "exit 0"           "$RUN_RC" "0"
assert_eq "numeric slug"     "$RUN_OUT" "123"

case_start "stax work-items slugify accepts leading-dash titles after --"
# `--` is honored as a legacy end-of-flags separator for backward compat
# with scripts that wrote it before the flag.Parse removal.
run_capture "" work-items slugify -- "-foo bar"
assert_eq "exit 0"           "$RUN_RC" "0"
assert_eq "leading-dash slug" "$RUN_OUT" "foo-bar"

case_start "stax work-items slugify accepts leading-dash titles WITHOUT --"
# runPlansSlugify deliberately bypasses flag.Parse so leading-dash titles
# work without the separator dance. This is the new ergonomic path; the
# `--` form above still works for backward compat.
run_capture "" work-items slugify "---foo---"
assert_eq "exit 0"            "$RUN_RC" "0"
assert_eq "leading-dash slug" "$RUN_OUT" "foo"
run_capture "" work-items slugify "--draft note"
assert_eq "exit 0"             "$RUN_RC" "0"
assert_eq "double-dash slug"   "$RUN_OUT" "draft-note"

case_start "stax work-items slugify drops non-ASCII; wholly-non-ASCII is unsluggable"
run_capture "" work-items slugify "Plan プラン"
assert_eq "exit 0"           "$RUN_RC" "0"
assert_eq "mixed slug"       "$RUN_OUT" "plan"
run_capture "" work-items slugify "プラン"
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "no slug-able characters"

case_start "stax work-items slugify collapses tabs and newlines"
# printf is run inside the same shell that invokes the binary, so escape
# sequences expand before the arg leaves the shell.
run_capture "" work-items slugify "$(printf 'Foo\tBar\nBaz')"
assert_eq "exit 0"           "$RUN_RC" "0"
assert_eq "ws-collapsed slug" "$RUN_OUT" "foo-bar-baz"

case_start "stax work-items slugify works outside a stax project"
# Pure transform; no project-marker check. Run from a directory with no .stax/
# to pin that contract.
PROJ_SG="$(fresh_project)"
cd "$PROJ_SG"
run_capture "" work-items slugify "Outside Project"
assert_eq "exit 0"        "$RUN_RC" "0"
assert_eq "slug printed"  "$RUN_OUT" "outside-project"

# ---------- per-subcommand --help / -h ----------

case_start "stax init -h prints init usage"
run_capture "" init -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "init usage header"  "$combined" "Usage: stax init"
assert_contains "agents flag listed" "$combined" "--agents"
assert_contains "scope flag listed"  "$combined" "--scope"

case_start "stax skills remove -h prints remove usage"
run_capture "" skills remove -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "remove usage header" "$combined" "Usage: stax skills remove"

case_start "stax work-items next-prefix -h prints next-prefix usage"
run_capture "" work-items next-prefix -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "next-prefix usage header" "$combined" "Usage: stax work-items next-prefix"

case_start "stax work-items lint -h prints lint usage"
run_capture "" work-items lint -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "lint usage header" "$combined" "Usage: stax work-items lint"

case_start "stax work-items slugify -h prints slugify usage"
run_capture "" work-items slugify -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "slugify usage header" "$combined" "Usage: stax work-items slugify"

# ---------- partial-state installs ----------

case_start "init recovers when only one agent's dir pre-exists"
reset_user_home
PROJ_PART="$(fresh_project)"
cd "$PROJ_PART"
mkdir -p "$PROJ_PART/${CLAUDE_CONFIG_REL}"
echo "USER" > "$PROJ_PART/${CLAUDE_CONFIG_REL}/CLAUDE.md"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_file "user CLAUDE.md preserved" "$PROJ_PART/${CLAUDE_CONFIG_REL}/CLAUDE.md"
assert_is_dir  "${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR} installed" "$PROJ_PART/${CLAUDE_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_dir  "${CODEX_SKILLS_REL}/${SKILL_SHIP_DIR} installed"  "$PROJ_PART/${CODEX_SKILLS_REL}/${SKILL_SHIP_DIR}"
assert_is_file "${CODEX_HOOKS_PATH} installed"                   "$PROJ_PART/${CODEX_HOOKS_PATH}"

# ---------- summary ----------

printf '\n----------------------------------------\n'
printf 'e2e: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
