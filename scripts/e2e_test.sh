#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# e2e_test.sh — End-to-end test driver for the x-x CLI.
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

readonly XX_HOME_DIR=".x-x"                       # xxHomeDir
readonly XX_CONFIG_FILE=".config.json"            # xxConfigFile
readonly AGENTS_EMBED_ROOT="agents"               # agentsEmbedRoot
readonly SKILLS_SUBDIR="skills"                   # skillsSubdir
readonly PLAN_DIR=".x-plan"                       # planDir
readonly PLAN_CONFIG_LOCK="_config.lock"          # planConfigLockFile
readonly PLAN_SYSTEMS_FILE="_data_systems.yaml"   # planSystemsFile
readonly DEFAULT_PREFIX_WIDTH=5                   # defaultPrefixWidth

# Bundled skill directory names (skill*Dir in constants.go).
readonly SKILL_SHARED_DIR="_x-x_shared"           # skillSharedDir
readonly SKILL_X_PLAN_DIR="x-plan"                # skillXPlanDir
readonly SKILL_X_X_DIR="x-x"                      # skillXXDir
# ownedSkills, flattened to a space-separated list for `for` iteration.
readonly OWNED_SKILLS="${SKILL_SHARED_DIR} ${SKILL_X_PLAN_DIR} ${SKILL_X_X_DIR}"

# agentTargets in constants.go — index 0 = Claude Code, 1 = Codex CLI.
readonly CLAUDE_SKILLS_REL=".claude/skills"       # agentTargets[0].skillsRel
readonly CLAUDE_CONFIG_REL=".claude"              # agentTargets[0].configRel
readonly CODEX_SKILLS_REL=".agents/skills"        # agentTargets[1].skillsRel
readonly CODEX_CONFIG_REL=".codex"                # agentTargets[1].configRel
# Parent of CODEX_SKILLS_REL — used by isolation cases that seed sibling
# files alongside the Codex skills dir. Derived (not a Go constant) to
# avoid drift if agentTargets[1].skillsRel ever moves.
readonly CODEX_SKILLS_PARENT="${CODEX_SKILLS_REL%/*}"

# Bundle-provided config filenames (agents/<configSrc>/* in the embed). Not
# named in constants.go (the embed tree is the source) but pinned here
# because the e2e asserts on their post-install presence.
readonly CLAUDE_SETTINGS_FILE="settings.json"
readonly CODEX_HOOKS_FILE="hooks.json"

# skipFromEmbed entry — the one file the embed walk omits.
readonly EMBED_README="README.md"

# Build stamp consumed by version-shape assertions.
readonly E2E_VERSION="v0.0.0-e2e"

# Compositions so call sites read as plain English.
readonly XX_AGENTS_DIR="${XX_HOME_DIR}/${AGENTS_EMBED_ROOT}"
readonly XX_AGENTS_SKILLS_DIR="${XX_AGENTS_DIR}/${SKILLS_SUBDIR}"
readonly PLAN_LOCK_PATH="${PLAN_DIR}/${PLAN_CONFIG_LOCK}"
readonly PLAN_SYSTEMS_PATH="${PLAN_DIR}/${PLAN_SYSTEMS_FILE}"
readonly CLAUDE_SETTINGS_PATH="${CLAUDE_CONFIG_REL}/${CLAUDE_SETTINGS_FILE}"
readonly CODEX_HOOKS_PATH="${CODEX_CONFIG_REL}/${CODEX_HOOKS_FILE}"

# ---------- locations ----------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d -t x-x-e2e.XXXXXX)"
# Build artifact lives inside the sandbox so nothing lands in the repo's
# working tree. The sandbox is wiped on exit via the trap below.
BUILD_BIN="${SANDBOX}/x-x-e2e"
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

# run_capture <stdin> <args...>  — runs x-x with given stdin string and args,
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

# reset_user_home — wipe the configured-agent dirs and ~/${XX_HOME_DIR}
# between cases so the next case starts from a known shape. Uses the
# constants block so adding a new agentTarget only requires updating that
# block.
reset_user_home() {
  rm -rf "$HOME/${CLAUDE_CONFIG_REL}" \
         "$HOME/${CODEX_CONFIG_REL}" \
         "$HOME/${CODEX_SKILLS_PARENT}" \
         "$HOME/${XX_HOME_DIR}"
}

# prefix <width> <n> — render n as a zero-padded prefix of the given width.
# Mirrors the binary's `fmt.Printf("%0*d\n", width, n)`.
prefix() { printf "%0${1}d" "$2"; }

# write_plan <dir> <name> <status> <inline-systems> — helper used by the
# `plan list` cases to seed a frontmatter-having plan file.
write_plan() {
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

# write_full_plan <dir> <name> <status> <inline-systems> <ears-subject> —
# seeds a plan that passes every lint check by default (frontmatter,
# required sections, EARS subject matching the declared system). Used by
# the `plan lint` cases as the baseline; individual cases override one
# field to trip a single finding.
write_full_plan() {
  local p="$1/$2"
  cat > "$p" <<EOF
---
status: $3
systems: [$4]
---

## Goal
Do a thing.

## Approach
- A

## Tasks
- [ ] The $5 shall do a thing.
EOF
}

# write_registry <dir> <name>[,<name>...] — seeds .x-plan/_data_systems.yaml
# with one entry per comma-separated name, slug derived from the name.
write_registry() {
  local p="$1/${PLAN_SYSTEMS_FILE}"
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

case_start "build x-x"
(
  cd "$REPO_ROOT"
  # -ldflags stamps a recognizable version so installer-shape assertions
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

# ---------- bare invocation ----------

case_start "x-x (bare) prints notice and bootstraps agents"
reset_user_home
run_capture ""
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "version line" "$RUN_OUT" "x-x by Stackific, ${E2E_VERSION}"
assert_contains "copyright"    "$RUN_OUT" "Copyright 2026 Stackific Inc."
assert_contains "spdx"         "$RUN_OUT" "SPDX-License-Identifier: Apache-2.0"
# Installer parses the version with `awk 'NR==1 { print $NF }'`. Pin that
# contract so future edits to printNotice don't silently break installs.
first_line_last_token="$(printf '%s' "$RUN_OUT" | awk 'NR==1 { print $NF; exit }')"
assert_eq "first-line last token is version" "$first_line_last_token" "${E2E_VERSION}"
assert_is_dir "lazy-bootstrap agents dir" "$HOME/${XX_AGENTS_DIR}"
assert_is_dir "lazy-bootstrap skill ${SKILL_X_X_DIR}" \
  "$HOME/${XX_AGENTS_SKILLS_DIR}/${SKILL_X_X_DIR}"

# ---------- --version ----------

case_start "x-x --version prints only notice"
reset_user_home
run_capture "" --version
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "version line" "$RUN_OUT" "x-x by Stackific, ${E2E_VERSION}"
assert_not_contains "no usage block" "$RUN_OUT" "Usage:"
assert_absent "no lazy bootstrap on --version" "$HOME/${XX_AGENTS_DIR}"

# ---------- -h / --help ----------

case_start "x-x -h prints notice + usage"
reset_user_home
run_capture "" -h
assert_eq "exit 0" "$RUN_RC" "0"
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "usage header"        "$combined" "Usage:"
assert_contains "init listed"         "$combined" "x-x init"
assert_not_contains "no bootstrap"    "$combined" "x-x bootstrap"
assert_contains "skill remove user"   "$combined" "x-x skill remove --user"
assert_contains "skill remove proj"   "$combined" "x-x skill remove --project"
assert_contains "plan next-prefix"    "$combined" "x-x plan next-prefix"
assert_contains "plan list"           "$combined" "x-x plan list"
assert_contains "version listed"      "$combined" "x-x --version"

# ---------- bootstrap is no longer a callable subcommand ----------

case_start "x-x bootstrap exits 2 (no longer a subcommand)"
reset_user_home
run_capture "" bootstrap
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "unknown subcommand: bootstrap"

# ---------- unknown subcommand ----------

case_start "x-x typo exits with code 2"
run_capture "" doesnotexist
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic on stderr" "$RUN_ERR" "unknown subcommand: doesnotexist"

# ---------- init --scope project ----------

case_start "x-x init --scope project end-to-end"
reset_user_home
PROJ="$(fresh_project)"
cd "$PROJ"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "progress line" "$RUN_OUT" "Setting up x-x in $PROJ"
assert_contains "completion"    "$RUN_OUT" "Done."
assert_contains "git-commit tip" "$RUN_OUT" "commit ${PLAN_DIR}/ to git"
for base in "${CLAUDE_SKILLS_REL}" "${CODEX_SKILLS_REL}"; do
  for skill in $OWNED_SKILLS; do
    assert_is_dir "project $base/$skill" "$PROJ/$base/$skill"
  done
done
assert_is_file "project ${CLAUDE_SETTINGS_PATH}" "$PROJ/${CLAUDE_SETTINGS_PATH}"
assert_is_file "project ${CODEX_HOOKS_PATH}"     "$PROJ/${CODEX_HOOKS_PATH}"
assert_is_file "${PLAN_LOCK_PATH} written"       "$PROJ/${PLAN_LOCK_PATH}"
assert_is_file "${PLAN_SYSTEMS_PATH} written"    "$PROJ/${PLAN_SYSTEMS_PATH}"
assert_contains "${PLAN_LOCK_PATH} has prefix_width" \
  "$(cat "$PROJ/${PLAN_LOCK_PATH}")" "\"prefix_width\": ${DEFAULT_PREFIX_WIDTH}"
assert_contains "${PLAN_LOCK_PATH} has plan_review_per" \
  "$(cat "$PROJ/${PLAN_LOCK_PATH}")" "\"plan_review_per\": \"task\""
assert_absent "${AGENTS_EMBED_ROOT}/${EMBED_README} not materialized" \
  "$HOME/${XX_AGENTS_DIR}/${EMBED_README}"

# ---------- init --scope user ----------

case_start "x-x init --scope user end-to-end"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope user
assert_eq "exit 0" "$RUN_RC" "0"
for base in "${CLAUDE_SKILLS_REL}" "${CODEX_SKILLS_REL}"; do
  for skill in $OWNED_SKILLS; do
    assert_is_symlink "user $base/$skill is symlink" "$HOME/$base/$skill"
    target="$(readlink "$HOME/$base/$skill")"
    case "$target" in
      "$HOME/${XX_AGENTS_SKILLS_DIR}/$skill")
        ok "user $base/$skill points to agentsTarget" ;;
      *)
        fail "user $base/$skill points to agentsTarget" "got=$target" ;;
    esac
  done
done

# ---------- init interactive prompts ----------
#
# init has TWO interactive questions (agents, then scope). Each pipe below
# answers both in order: first line = agents, second = scope. A blank first
# line accepts the default (all agents). Per AGENTS.md rule 9, every prompt
# must also have a flag-driven equivalent — covered in the `init --agents
# / --scope flag forms` block further down.

case_start "x-x init interactive (default agents + project scope)"
reset_user_home
PROJ_INT="$(fresh_project)"
cd "$PROJ_INT"
run_capture "
1
" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir  "interactive project skill" "$PROJ_INT/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_is_file "interactive plan lock"     "$PROJ_INT/${PLAN_LOCK_PATH}"

case_start "x-x init interactive (default agents + user scope)"
reset_user_home
cd "$(fresh_project)"
run_capture "
2
" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_exists "interactive user skill" "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"

case_start "x-x init interactive (explicit agents + project scope)"
reset_user_home
PROJ_INT2="$(fresh_project)"
cd "$PROJ_INT2"
run_capture "1,2
1
" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "interactive explicit agents installs claude" "$PROJ_INT2/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_is_dir "interactive explicit agents installs codex"  "$PROJ_INT2/${CODEX_SKILLS_REL}/${SKILL_X_X_DIR}"

case_start "x-x init interactive (invalid agent choice)"
reset_user_home
cd "$(fresh_project)"
run_capture "9
" init
[ "$RUN_RC" != "0" ] && ok "non-zero exit on invalid agent choice" || fail "non-zero exit on invalid agent choice"
assert_contains "diagnostic on stderr" "$RUN_ERR" "invalid agent choice"

case_start "x-x init interactive (invalid scope choice)"
reset_user_home
cd "$(fresh_project)"
run_capture "
9
" init
[ "$RUN_RC" != "0" ] && ok "non-zero exit on invalid scope choice" || fail "non-zero exit on invalid scope choice"
assert_contains "diagnostic on stderr" "$RUN_ERR" "invalid choice"

# ---------- init --agents / --scope flag forms (non-interactive twins) ----------

case_start "x-x init --agents=claude installs only Claude Code"
reset_user_home
PROJ_AC="$(fresh_project)"
cd "$PROJ_AC"
run_capture "" init --agents=claude --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "claude installed" "$PROJ_AC/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_absent "codex NOT installed" "$PROJ_AC/${CODEX_SKILLS_REL}"

case_start "x-x init --agents=codex installs only Codex CLI"
reset_user_home
PROJ_AX="$(fresh_project)"
cd "$PROJ_AX"
run_capture "" init --agents=codex --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "codex installed" "$PROJ_AX/${CODEX_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_absent "claude NOT installed" "$PROJ_AX/${CLAUDE_SKILLS_REL}"

case_start "x-x init --agents=claude,codex (both)"
reset_user_home
PROJ_AB="$(fresh_project)"
cd "$PROJ_AB"
run_capture "" init --agents=claude,codex --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "claude installed" "$PROJ_AB/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_is_dir "codex installed"  "$PROJ_AB/${CODEX_SKILLS_REL}/${SKILL_X_X_DIR}"

case_start "x-x init --agents=invalid rejects unknown agent"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --agents=workspace --scope=project
[ "$RUN_RC" != "0" ] && ok "non-zero exit" || fail "non-zero exit"
assert_contains "diagnostic" "$RUN_ERR" "unknown agent"

# ---------- init --scope invalid ----------

case_start "x-x init --scope invalid"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope workspace
[ "$RUN_RC" != "0" ] && ok "non-zero exit" || fail "non-zero exit"
assert_contains "diagnostic" "$RUN_ERR" "invalid --scope"

# ---------- init overwrites prior content at owned skill names ----------

case_start "init clobbers prior content at owned skill names"
reset_user_home
PROJ_OW="$(fresh_project)"
cd "$PROJ_OW"
mkdir -p "$PROJ_OW/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
echo "STALE" > "$PROJ_OW/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}/STALE"
run_capture "" init --scope project
assert_absent "stale file gone after init" "$PROJ_OW/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}/STALE"
assert_is_dir "sibling skill installed"    "$PROJ_OW/${CLAUDE_SKILLS_REL}/${SKILL_X_PLAN_DIR}"

# ---------- skill (no subcommand) ----------

case_start "x-x skill (no subcommand)"
run_capture "" skill
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: x-x skill <subcommand>"

case_start "x-x skill <typo>"
run_capture "" skill frobnicate
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "unknown skill subcommand: frobnicate"

# ---------- skill remove (no flag) ----------

case_start "x-x skill remove (no flag)"
run_capture "" skill remove
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: x-x skill remove"

# ---------- skill remove --user + --project (mutex) ----------

case_start "x-x skill remove --user --project (mutex)"
run_capture "" skill remove --user --project
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "mutually exclusive"

# ---------- skill remove --user (end-to-end) ----------

case_start "x-x skill remove --user"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope user
mkdir -p "$HOME/${CLAUDE_SKILLS_REL}/my-custom"
touch "$HOME/${CLAUDE_SKILLS_REL}/my-custom/marker"
run_capture "" skill remove --user
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "summary" "$RUN_OUT" "Removed"
for skill in $OWNED_SKILLS; do
  assert_absent "user $skill removed" "$HOME/${CLAUDE_SKILLS_REL}/$skill"
done
assert_is_file "user-authored skill survives" "$HOME/${CLAUDE_SKILLS_REL}/my-custom/marker"

# ---------- skill remove --project (end-to-end) ----------

case_start "x-x skill remove --project"
reset_user_home
PROJ_RM="$(fresh_project)"
cd "$PROJ_RM"
run_capture "" init --scope project
mkdir -p "$PROJ_RM/${CLAUDE_SKILLS_REL}/my-custom"
touch "$PROJ_RM/${CLAUDE_SKILLS_REL}/my-custom/marker"
run_capture "" skill remove --project
assert_eq "exit 0" "$RUN_RC" "0"
for skill in $OWNED_SKILLS; do
  assert_absent "project $skill removed" "$PROJ_RM/${CLAUDE_SKILLS_REL}/$skill"
done
assert_is_file "user-authored skill survives"      "$PROJ_RM/${CLAUDE_SKILLS_REL}/my-custom/marker"
assert_is_file "${PLAN_LOCK_PATH} preserved"       "$PROJ_RM/${PLAN_LOCK_PATH}"
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
assert_is_dir "bundled ${SKILL_X_X_DIR} landed"    "$PROJ_ISO/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_is_dir "bundled ${SKILL_X_PLAN_DIR} landed" "$PROJ_ISO/${CODEX_SKILLS_REL}/${SKILL_X_PLAN_DIR}"

# ---------- isolation: init re-run keeps user-edited config files ----------

case_start "init re-run preserves edited ${CLAUDE_SETTINGS_FILE} + ${CODEX_HOOKS_FILE}"
reset_user_home
PROJ_RE="$(fresh_project)"
cd "$PROJ_RE"
run_capture "" init --scope project
echo '{"USER": "EDIT"}' > "$PROJ_RE/${CLAUDE_SETTINGS_PATH}"
echo '{"USER": "EDIT"}' > "$PROJ_RE/${CODEX_HOOKS_PATH}"
echo "USER PIN" > "$PROJ_RE/${PLAN_LOCK_PATH}"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "${CLAUDE_SETTINGS_FILE} preserved" "$(cat "$PROJ_RE/${CLAUDE_SETTINGS_PATH}")" '{"USER": "EDIT"}'
assert_eq "${CODEX_HOOKS_FILE} preserved"     "$(cat "$PROJ_RE/${CODEX_HOOKS_PATH}")"     '{"USER": "EDIT"}'
assert_eq "${PLAN_CONFIG_LOCK} preserved"     "$(cat "$PROJ_RE/${PLAN_LOCK_PATH}")"       "USER PIN"

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
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_file "sibling claude skill survives re-run" "$PROJ_SIB/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
assert_is_file "sibling agents skill survives re-run" "$PROJ_SIB/${CODEX_SKILLS_REL}/their-custom/SKILL.md"
assert_is_dir  "bundled ${SKILL_X_X_DIR} present after re-run" \
  "$PROJ_SIB/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"

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
run_capture "" skill remove --project
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
  "${PLAN_LOCK_PATH}" \
  "${PLAN_SYSTEMS_PATH}"; do
  assert_is_file "skill remove kept $p" "$PROJ_RMI/$p"
done
for skill in $OWNED_SKILLS; do
  assert_absent "skill remove dropped ${CLAUDE_SKILLS_REL}/$skill" "$PROJ_RMI/${CLAUDE_SKILLS_REL}/$skill"
  assert_absent "skill remove dropped ${CODEX_SKILLS_REL}/$skill"  "$PROJ_RMI/${CODEX_SKILLS_REL}/$skill"
done

# ---------- isolation: lazy first-run write keeps foreign content ----------
#
# Lazy first-run is "create iff missing" — it never touches a tree that
# already exists. Foreign files dropped into ~/${XX_AGENTS_DIR} after the
# first run survive subsequent bare invocations *until* the 24h refresh
# fires (covered by the next case). Without a .config.json present,
# maybeNotifyUpdate returns early and the refresh never runs.

case_start "lazy first-run write leaves foreign content under \$HOME/${XX_AGENTS_DIR} alone"
reset_user_home
run_capture "" >/dev/null
assert_is_dir "agents dir exists" "$HOME/${XX_AGENTS_DIR}"
echo "USER" > "$HOME/${XX_AGENTS_DIR}/USER-NOTE.md"
mkdir -p "$HOME/${XX_AGENTS_DIR}/my-private-skill"
echo "USER" > "$HOME/${XX_AGENTS_DIR}/my-private-skill/SKILL.md"
# Bare invocation with no .config.json → no update check → no refresh.
run_capture ""
assert_is_file "user file survives without 24h refresh" \
  "$HOME/${XX_AGENTS_DIR}/USER-NOTE.md"
assert_is_file "user skill survives without 24h refresh" \
  "$HOME/${XX_AGENTS_DIR}/my-private-skill/SKILL.md"

# ---------- 24h update check rewrites $HOME/<XX_AGENTS_DIR> from embed ----------

case_start "24h update check rewrites bundled agents tree"
reset_user_home
PROJ_REF="$(fresh_project)"
# 1) Lazy first-run write seeds the agents tree.
run_capture "" >/dev/null
assert_is_dir "agents tree seeded" "$HOME/${XX_AGENTS_DIR}"
# 2) Install project skills so we can verify the refresh DOESN'T touch them.
cd "$PROJ_REF"
run_capture "" init --agents=claude,codex --scope=project
echo "MINE" > "$PROJ_REF/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}/PROJECT-LOCAL"
# 3) Drop a stale file under the global tree — the 24h refresh must wipe it.
echo "STALE" > "$HOME/${XX_AGENTS_DIR}/STALE.md"
# 4) Backdate .config.json so the 24h cadence triggers immediately. The
#    binary's stamped version is recorded so no upgrade nudge fires.
echo "{\"version\":\"${E2E_VERSION}\",\"last_checked\":0}" \
  > "$HOME/${XX_HOME_DIR}/${XX_CONFIG_FILE}"
# 5) Bare invocation fires the update check → writeBundledAgents(true).
run_capture ""
assert_eq "exit 0" "$RUN_RC" "0"
assert_absent "stale file wiped by 24h refresh" "$HOME/${XX_AGENTS_DIR}/STALE.md"
assert_is_dir "bundled skill present after refresh" \
  "$HOME/${XX_AGENTS_SKILLS_DIR}/${SKILL_X_X_DIR}"
# 6) Project-local content MUST be untouched.
assert_is_file "project-local file untouched by global refresh" \
  "$PROJ_REF/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}/PROJECT-LOCAL"
# 7) last_checked got bumped → a second back-to-back run does NOT refresh.
echo "POST" > "$HOME/${XX_AGENTS_DIR}/POST.md"
run_capture ""
assert_is_file "post-check sentinel survives next bare run" \
  "$HOME/${XX_AGENTS_DIR}/POST.md"

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
assert_is_symlink "user-scope bundled ${SKILL_X_X_DIR}"    "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_is_symlink "user-scope bundled ${SKILL_X_PLAN_DIR}" "$HOME/${CODEX_SKILLS_REL}/${SKILL_X_PLAN_DIR}"

# ---------- isolation: init --scope user re-run preserves user edits ----------

case_start "init --scope user re-run preserves edited ${CLAUDE_SETTINGS_FILE} + ${CODEX_HOOKS_FILE}"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope user
echo '{"USER": "EDIT"}' > "$HOME/${CLAUDE_SETTINGS_PATH}"
echo '{"USER": "EDIT"}' > "$HOME/${CODEX_HOOKS_PATH}"
run_capture "" init --scope user
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "user ${CLAUDE_SETTINGS_FILE} preserved" "$(cat "$HOME/${CLAUDE_SETTINGS_PATH}")" '{"USER": "EDIT"}'
assert_eq "user ${CODEX_HOOKS_FILE} preserved"     "$(cat "$HOME/${CODEX_HOOKS_PATH}")"     '{"USER": "EDIT"}'

# ---------- isolation: init --scope user re-run keeps sibling skills ----------

case_start "init --scope user re-run keeps user-authored sibling skills"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope user
mkdir -p "$HOME/${CLAUDE_SKILLS_REL}/my-custom"
echo "MINE" > "$HOME/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
run_capture "" init --scope user
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_file    "user-scope sibling survives re-run" "$HOME/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
assert_is_symlink "user-scope bundled still symlinked" "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"

# ---------- skill remove on empty state ----------

case_start "skill remove --user is a silent no-op when nothing is installed"
reset_user_home
# Trigger the lazy first-run write of ~/${XX_HOME_DIR}/agents/ via bare
# x-x, then wipe the install dirs so skill remove has nothing to do.
run_capture "" >/dev/null
rm -rf "$HOME/${CLAUDE_CONFIG_REL}" "$HOME/${CODEX_SKILLS_PARENT}" "$HOME/${CODEX_CONFIG_REL}"
run_capture "" skill remove --user
assert_eq "exit 0 on empty state" "$RUN_RC" "0"
assert_contains "summary line" "$RUN_OUT" "Removed 0"

case_start "skill remove --project outside an x-x project"
reset_user_home
cd "$(fresh_project)"
run_capture "" skill remove --project
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not an x-x project"
assert_contains "hint"       "$RUN_ERR" "x-x init"

case_start "skill remove --project is a silent no-op when only the scaffold exists"
reset_user_home
PROJ_RM_EMPTY="$(fresh_project)"
mkdir -p "$PROJ_RM_EMPTY/${PLAN_DIR}"
cd "$PROJ_RM_EMPTY"
run_capture "" skill remove --project
assert_eq "exit 0 on empty state" "$RUN_RC" "0"
assert_contains "summary line" "$RUN_OUT" "Removed 0"

# ---------- idempotency: re-running has zero net effect ----------

case_start "bare x-x is idempotent (no re-bootstrap)"
reset_user_home
run_capture ""
sentinel_path="$HOME/${XX_AGENTS_SKILLS_DIR}/${SKILL_X_X_DIR}/SKILL.md"
first_mtime="$(stat -f %m "$sentinel_path" 2>/dev/null || stat -c %Y "$sentinel_path")"
sleep 1
run_capture ""
second_mtime="$(stat -f %m "$sentinel_path" 2>/dev/null || stat -c %Y "$sentinel_path")"
assert_eq "mtime unchanged across runs" "$first_mtime" "$second_mtime"

case_start "init --scope project is idempotent across back-to-back runs"
reset_user_home
PROJ_IDEM="$(fresh_project)"
cd "$PROJ_IDEM"
# Portable cross-platform tree fingerprint: filename, type marker, and
# either symlink target or file size. Avoids depending on `shasum` or
# `sha256sum`, which differ between Debian and macOS.
tree_fingerprint() {
  find "$1" \( -type f -o -type l -o -type d \) -print 2>/dev/null | sort | while read -r p; do
    if [ -L "$p" ]; then
      printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
    elif [ -d "$p" ]; then
      printf 'D %s\n' "$p"
    else
      printf 'F %s %s\n' "$p" "$(wc -c <"$p" | tr -d ' ')"
    fi
  done
}
run_capture "" init --scope project
snap1="$(tree_fingerprint "$PROJ_IDEM")"
run_capture "" init --scope project
snap2="$(tree_fingerprint "$PROJ_IDEM")"
assert_eq "exit 0 second run" "$RUN_RC" "0"
assert_eq "project tree shape identical after re-init" "$snap1" "$snap2"

# ---------- CLI flag forms ----------

case_start "--scope=project (equals form)"
reset_user_home
PROJ_EQ="$(fresh_project)"
cd "$PROJ_EQ"
run_capture "" init --scope=project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "scope=project installed" "$PROJ_EQ/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"

case_start "--scope=user (equals form)"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope=user
assert_eq "exit 0" "$RUN_RC" "0"
assert_exists "scope=user installed" "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"

# ---------- init runs cleanly when $HOME/${XX_AGENTS_DIR} is missing ----------

case_start "init bootstraps \$HOME/${XX_AGENTS_DIR} on first run"
reset_user_home
assert_absent "agents dir starts missing" "$HOME/${XX_AGENTS_DIR}"
cd "$(fresh_project)"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir "init materialized agents" "$HOME/${XX_AGENTS_SKILLS_DIR}/${SKILL_X_X_DIR}"

# ---------- stream discipline: stdout vs stderr ----------

case_start "bare invocation writes only to stdout"
reset_user_home
run_capture ""
[ -z "$RUN_ERR" ] && ok "stderr empty" || fail "stderr empty" "got: $RUN_ERR"

case_start "init --scope project writes progress to stdout, not stderr"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project
assert_contains "progress on stdout" "$RUN_OUT" "Installing"
assert_not_contains "no progress on stderr" "$RUN_ERR" "Installing"

# ---------- plan next-prefix ----------

case_start "x-x plan (no subcommand)"
run_capture "" plan
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: x-x plan <subcommand>"

case_start "x-x plan <typo>"
run_capture "" plan frobnicate
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "unknown plan subcommand: frobnicate"

case_start "x-x plan next-prefix outside an x-x project"
PROJ_NP="$(fresh_project)"
cd "$PROJ_NP"
run_capture "" plan next-prefix
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not an x-x project"
assert_contains "hint"       "$RUN_ERR" "x-x init"

case_start "x-x plan next-prefix in fresh ${PLAN_DIR} (empty)"
PROJ_NP_EMPTY="$(fresh_project)"
mkdir -p "$PROJ_NP_EMPTY/${PLAN_DIR}"
cd "$PROJ_NP_EMPTY"
run_capture "" plan next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "first prefix" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "x-x plan next-prefix with default width"
PROJ_NP2="$(fresh_project)"
mkdir -p "$PROJ_NP2/${PLAN_DIR}"
touch "$PROJ_NP2/${PLAN_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
      "$PROJ_NP2/${PLAN_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-bar.md"
cd "$PROJ_NP2"
run_capture "" plan next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "max+1 default width" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 4)"

case_start "x-x plan next-prefix honors ${PLAN_CONFIG_LOCK} prefix_width"
PROJ_NP3="$(fresh_project)"
mkdir -p "$PROJ_NP3/${PLAN_DIR}"
custom_width=7
echo "{\"prefix_width\":${custom_width}}" > "$PROJ_NP3/${PLAN_LOCK_PATH}"
touch "$PROJ_NP3/${PLAN_DIR}/$(prefix "$custom_width" 41)-foo.md"
cd "$PROJ_NP3"
run_capture "" plan next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "custom width applied" "$RUN_OUT" "$(prefix "$custom_width" 42)"

case_start "x-x plan next-prefix rejects positional arg"
cd "$(fresh_project)"
run_capture "" plan next-prefix some/dir
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no arguments"

case_start "x-x plan next-prefix ignores non-matching filenames"
PROJ_NP4="$(fresh_project)"
mkdir -p "$PROJ_NP4/${PLAN_DIR}"
touch "$PROJ_NP4/${PLAN_DIR}/notes.md" \
      "$PROJ_NP4/${PLAN_DIR}/README" \
      "$PROJ_NP4/${PLAN_DIR}/abc-foo.md" \
      "$PROJ_NP4/${PLAN_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 7)-real.md"
cd "$PROJ_NP4"
run_capture "" plan next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "non-matching ignored" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 8)"

case_start "x-x plan next-prefix with only lock file (no plan files)"
PROJ_NP5="$(fresh_project)"
mkdir -p "$PROJ_NP5/${PLAN_DIR}"
echo "{\"prefix_width\":${DEFAULT_PREFIX_WIDTH}}" > "$PROJ_NP5/${PLAN_LOCK_PATH}"
cd "$PROJ_NP5"
run_capture "" plan next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "lock-only → first prefix" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "x-x plan next-prefix falls back to default width on malformed lock"
PROJ_NP6="$(fresh_project)"
mkdir -p "$PROJ_NP6/${PLAN_DIR}"
echo '{not json' > "$PROJ_NP6/${PLAN_LOCK_PATH}"
cd "$PROJ_NP6"
run_capture "" plan next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "default width on bad lock" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "x-x plan next-prefix falls back to default width on zero prefix_width"
PROJ_NP7="$(fresh_project)"
mkdir -p "$PROJ_NP7/${PLAN_DIR}"
echo '{"prefix_width":0}' > "$PROJ_NP7/${PLAN_LOCK_PATH}"
cd "$PROJ_NP7"
run_capture "" plan next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "default width on zero" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "x-x plan next-prefix rolls past width digits"
PROJ_NP8="$(fresh_project)"
mkdir -p "$PROJ_NP8/${PLAN_DIR}"
touch "$PROJ_NP8/${PLAN_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 99999)-last.md"
cd "$PROJ_NP8"
run_capture "" plan next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
# 99999+1 = 100000 — fmt %0*d at width 5 prints "100000" (no truncation).
assert_eq "overflow keeps counting" "$RUN_OUT" "100000"

# ---------- plan list ----------

case_start "x-x plan list (empty ${PLAN_DIR})"
PROJ_PL1="$(fresh_project)"
mkdir -p "$PROJ_PL1/${PLAN_DIR}"
cd "$PROJ_PL1"
run_capture "" plan list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "no rows on empty" "$RUN_OUT" ""

case_start "x-x plan list outside an x-x project"
PROJ_PL2="$(fresh_project)"
cd "$PROJ_PL2"
run_capture "" plan list
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not an x-x project"
assert_contains "hint"       "$RUN_ERR" "x-x init"

case_start "x-x plan list emits tab-separated rows sorted by prefix"
PROJ_PL3="$(fresh_project)"
mkdir -p "$PROJ_PL3/${PLAN_DIR}"
write_plan "$PROJ_PL3/${PLAN_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-bravo.md"   "deprecated" "Billing"
write_plan "$PROJ_PL3/${PLAN_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md"   "valid"      "Auth, Billing"
write_plan "$PROJ_PL3/${PLAN_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-charlie.md" "superseded" "Auth"
cd "$PROJ_PL3"
run_capture "" plan list
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-alpha\tvalid\tAuth,Billing\n%s-bravo\tdeprecated\tBilling\n%s-charlie\tsuperseded\tAuth' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)")"
assert_eq "sorted tab-separated rows" "$RUN_OUT" "$expected"

case_start "x-x plan list --status filters"
cd "$PROJ_PL3"
run_capture "" plan list --status valid
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "status filter keeps only valid" "$RUN_OUT" \
  "$(printf '%s-alpha\tvalid\tAuth,Billing' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "x-x plan list --status comma list"
cd "$PROJ_PL3"
run_capture "" plan list --status valid,superseded
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-alpha\tvalid\tAuth,Billing\n%s-charlie\tsuperseded\tAuth' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)")"
assert_eq "comma status filter" "$RUN_OUT" "$expected"

case_start "x-x plan list --system OR semantics"
cd "$PROJ_PL3"
run_capture "" plan list --system Billing
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-alpha\tvalid\tAuth,Billing\n%s-bravo\tdeprecated\tBilling' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)")"
assert_eq "system filter matches any" "$RUN_OUT" "$expected"

case_start "x-x plan list combined --status and --system"
cd "$PROJ_PL3"
run_capture "" plan list --status valid --system Auth
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "status+system intersection" "$RUN_OUT" \
  "$(printf '%s-alpha\tvalid\tAuth,Billing' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "x-x plan list warns on malformed frontmatter but keeps siblings"
PROJ_PL4="$(fresh_project)"
mkdir -p "$PROJ_PL4/${PLAN_DIR}"
broken_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-broken.md"
ok_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-ok.md"
echo "not a plan" > "$PROJ_PL4/${PLAN_DIR}/$broken_name"
write_plan "$PROJ_PL4/${PLAN_DIR}" "$ok_name" "valid" "Auth"
cd "$PROJ_PL4"
run_capture "" plan list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "broken skipped, ok kept" "$RUN_OUT" \
  "$(printf '%s\tvalid\tAuth' "${ok_name%.md}")"
assert_contains "warning to stderr" "$RUN_ERR" "$broken_name"

case_start "x-x plan list ignores non-matching filenames"
PROJ_PL5="$(fresh_project)"
mkdir -p "$PROJ_PL5/${PLAN_DIR}"
keep_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-keep.md"
write_plan "$PROJ_PL5/${PLAN_DIR}" "$keep_name" "valid" "Auth"
echo "x" > "$PROJ_PL5/${PLAN_DIR}/README.md"
echo "x" > "$PROJ_PL5/${PLAN_DIR}/123-short.md"
echo "x" > "$PROJ_PL5/${PLAN_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-no-ext"
cd "$PROJ_PL5"
run_capture "" plan list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "only keep matched" "$RUN_OUT" "$(printf '%s\tvalid\tAuth' "${keep_name%.md}")"
[ -z "$RUN_ERR" ] && ok "no spurious warnings" || fail "no spurious warnings" "got: $RUN_ERR"

case_start "x-x plan list rejects positional args"
cd "$(fresh_project)"
run_capture "" plan list foo
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no positional"

# ---------- plan lint ----------

case_start "x-x plan lint outside an x-x project"
PROJ_LN0="$(fresh_project)"
cd "$PROJ_LN0"
run_capture "" plan lint
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not an x-x project"
assert_contains "hint"       "$RUN_ERR" "x-x init"

case_start "x-x plan lint happy path"
PROJ_LN1="$(fresh_project)"
mkdir -p "$PROJ_LN1/${PLAN_DIR}"
write_registry "$PROJ_LN1/${PLAN_DIR}" "Auth Service"
plan1_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
write_full_plan "$PROJ_LN1/${PLAN_DIR}" "$plan1_name" "valid" "Auth Service" "Auth Service"
cd "$PROJ_LN1"
run_capture "" plan lint
assert_eq "exit 0"               "$RUN_RC" "0"
assert_contains "ok line"        "$RUN_OUT" "$plan1_name: ok"
assert_contains "summary 1 ok"   "$RUN_ERR" "1 ok, 0 failed"

case_start "x-x plan lint flags bad filename"
PROJ_LN2="$(fresh_project)"
mkdir -p "$PROJ_LN2/${PLAN_DIR}"
write_registry "$PROJ_LN2/${PLAN_DIR}" "Auth Service"
write_full_plan "$PROJ_LN2/${PLAN_DIR}" "BAD-NAME.md" "valid" "Auth Service" "Auth Service"
cd "$PROJ_LN2"
run_capture "" plan lint
assert_eq "exit 1"               "$RUN_RC" "1"
assert_contains "filename finding" "$RUN_OUT" "does not match <prefix>-<slug>.md"

case_start "x-x plan lint flags missing frontmatter"
PROJ_LN3="$(fresh_project)"
mkdir -p "$PROJ_LN3/${PLAN_DIR}"
write_registry "$PROJ_LN3/${PLAN_DIR}" "Auth Service"
broken_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-broken.md"
echo "just body, no frontmatter" > "$PROJ_LN3/${PLAN_DIR}/$broken_name"
cd "$PROJ_LN3"
run_capture "" plan lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "frontmatter finding" "$RUN_OUT" "missing YAML frontmatter"

case_start "x-x plan lint flags bad status"
PROJ_LN4="$(fresh_project)"
mkdir -p "$PROJ_LN4/${PLAN_DIR}"
write_registry "$PROJ_LN4/${PLAN_DIR}" "Auth Service"
write_full_plan "$PROJ_LN4/${PLAN_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "bogus" "Auth Service" "Auth Service"
cd "$PROJ_LN4"
run_capture "" plan lint
assert_eq "exit 1"           "$RUN_RC" "1"
assert_contains "bad status" "$RUN_OUT" "status \"bogus\" is not one of"

case_start "x-x plan lint flags system not in registry"
PROJ_LN5="$(fresh_project)"
mkdir -p "$PROJ_LN5/${PLAN_DIR}"
write_registry "$PROJ_LN5/${PLAN_DIR}" "Auth Service"
write_full_plan "$PROJ_LN5/${PLAN_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "valid" "Ghost Service" "Ghost Service"
cd "$PROJ_LN5"
run_capture "" plan lint
assert_eq "exit 1"                "$RUN_RC" "1"
assert_contains "system finding"  "$RUN_OUT" "declared system \"Ghost Service\" is not in"

case_start "x-x plan lint flags dangling supersedes"
PROJ_LN6="$(fresh_project)"
mkdir -p "$PROJ_LN6/${PLAN_DIR}"
write_registry "$PROJ_LN6/${PLAN_DIR}" "Auth Service"
super_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN6/${PLAN_DIR}/$super_name" <<EOF
---
status: valid
systems: [Auth Service]
supersedes: [00099-nope]
---

## Goal
g

## Approach
- A

## Tasks
- [ ] The Auth Service shall do.
EOF
cd "$PROJ_LN6"
run_capture "" plan lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "supersedes finding" "$RUN_OUT" "supersedes \"00099-nope\""

case_start "x-x plan lint flags EARS-systems mismatch"
PROJ_LN7="$(fresh_project)"
mkdir -p "$PROJ_LN7/${PLAN_DIR}"
write_registry "$PROJ_LN7/${PLAN_DIR}" "Auth Service,Billing Service"
# Declares Auth but task names Billing — both diff directions fire.
write_full_plan "$PROJ_LN7/${PLAN_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "valid" "Auth Service" "Billing Service"
cd "$PROJ_LN7"
run_capture "" plan lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "EARS-not-in-systems"    "$RUN_OUT" "EARS tasks name systems not in \`systems:\`"
assert_contains "systems-not-in-tasks"   "$RUN_OUT" "\`systems:\` declares systems not used in any EARS task"

case_start "x-x plan lint rejects positional arg"
cd "$(fresh_project)"
run_capture "" plan lint somearg
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no arguments"

# ---------- per-subcommand --help / -h ----------

case_start "x-x init -h prints init usage"
run_capture "" init -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "init usage header"  "$combined" "Usage: x-x init"
assert_contains "agents flag listed" "$combined" "--agents"
assert_contains "scope flag listed"  "$combined" "--scope"

case_start "x-x skill remove -h prints remove usage"
run_capture "" skill remove -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "remove usage header" "$combined" "Usage: x-x skill remove"

case_start "x-x plan next-prefix -h prints next-prefix usage"
run_capture "" plan next-prefix -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "next-prefix usage header" "$combined" "Usage: x-x plan next-prefix"

case_start "x-x plan lint -h prints lint usage"
run_capture "" plan lint -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "lint usage header" "$combined" "Usage: x-x plan lint"

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
assert_is_dir  "${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR} installed" "$PROJ_PART/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_is_dir  "${CODEX_SKILLS_REL}/${SKILL_X_X_DIR} installed"  "$PROJ_PART/${CODEX_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_is_file "${CODEX_HOOKS_PATH} installed"                   "$PROJ_PART/${CODEX_HOOKS_PATH}"

# ---------- summary ----------

printf '\n----------------------------------------\n'
printf 'e2e: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
