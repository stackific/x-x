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
readonly PLANS_DIR=".x-plans"                      # plansDir
readonly PLANS_CONFIG_LOCK="_config.lock"          # plansConfigLockFile
readonly PLANS_SYSTEMS_FILE="_data_systems.yaml"   # plansSystemsFile
readonly DEFAULT_PREFIX_WIDTH=4                    # defaultPrefixWidth
readonly PLANS_LIST_OVERFLOW_THRESHOLD=20          # plansListOverflowThreshold

# Bundled skill directory names (skill*Dir in constants.go).
readonly SKILL_SHARED_DIR="_x-x_shared"           # skillSharedDir
readonly SKILL_X_PLAN_DIR="x-plan"                # skillXPlanDir
readonly SKILL_X_X_DIR="x-x"                      # skillXXDir
readonly SKILL_MANIFEST_FILE="SKILL.md"           # skillManifestFile

# Filenames under agents/skills/_x-x_shared/ (sharedDoc* in constants.go).
readonly SHARED_DOC_PLAN_FIRST="_plan_first.md"   # sharedDocPlanFirst
readonly SHARED_DOC_SYSTEMS="_systems.md"         # sharedDocSystems
readonly SHARED_DOC_EARS="_ears.md"               # sharedDocEars
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
readonly PLANS_LOCK_PATH="${PLANS_DIR}/${PLANS_CONFIG_LOCK}"
readonly PLANS_SYSTEMS_PATH="${PLANS_DIR}/${PLANS_SYSTEMS_FILE}"
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

# seed_project_scaffold <dir> — creates the minimal "fully initialized x-x
# project" shape that `checkProject` requires: the planDir directory plus
# the two scaffold files (`_data_systems.yaml`, `_config.lock`) that
# `x-x init` would write. Used by every `plan *` / `skill remove --project`
# case that exercises the gate's happy path without running `x-x init`
# itself. The two files are zero-byte placeholders — exactly what an
# empty fresh project looks like — so individual cases can overwrite
# them with case-specific content (e.g. a custom prefix_width lock).
seed_project_scaffold() {
  mkdir -p "$1/${PLANS_DIR}"
  : > "$1/${PLANS_DIR}/${PLANS_SYSTEMS_FILE}"
  : > "$1/${PLANS_DIR}/${PLANS_CONFIG_LOCK}"
}

# prefix <width> <n> — render n as a zero-padded prefix of the given width.
# Mirrors the binary's `fmt.Printf("%0*d\n", width, n)`.
prefix() { printf "%0${1}d" "$2"; }

# sha256_of <path> — print the SHA-256 hex digest of the file at <path>,
# resolving through symlinks (so user-scope installs that link into
# ~/.x-x/agents/ still produce the digest of the linked-to bytes).
# Portable across Linux (`sha256sum`) and macOS (`shasum -a 256`).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

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

# write_plan_body <dir> <name> <body> — seeds a plan whose body is exactly
# <body>. Used by the overflow-keywords cases that need predictable body
# content for regex matching. The `systems:` array carries a kebab id so
# the plan is round-trippable through `--system auth`.
write_plan_body() {
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
# Seeds <count> plans with predictable slugs (NNNNN-planNNN) and bodies
# formatted as "<body-template> N". Body-template may carry shell-safe
# substitution markers like '%KEY%' if the caller post-processes them.
seed_many_plans() {
  local dir="$1" count="$2" body_template="$3"
  local i name pad
  for (( i=1; i<=count; i++ )); do
    pad="$(printf '%03d' "$i")"
    name="$(prefix "$DEFAULT_PREFIX_WIDTH" "$i")-plan${pad}.md"
    write_plan_body "$dir" "$name" "${body_template} ${i}"
  done
}

# write_full_plan <dir> <name> <status> <inline-system-ids> <ears-subject-name> —
# seeds a plan that passes every lint check by default (frontmatter,
# required sections, EARS subject name resolving to the declared system id
# via the registry). Used by the `plan lint` cases as the baseline;
# individual cases override one field to trip a single finding. The 4th
# arg goes into `systems:` (kebab ids); the 5th arg goes into the EARS
# subject (display name). They are two coordinates of the same registry
# entry — the linter resolves the subject name to its id and checks the
# id set against the declared ids.
#
# The title is derived from the filename slug so the title↔filename lint
# stays satisfied; cases that intentionally break the filename also fail
# lintFilename, which short-circuits the title↔filename check.
write_full_plan() {
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

# write_registry <dir> <name>[,<name>...] — seeds .x-plans/_data_systems.yaml
# with one entry per comma-separated name, slug derived from the name.
write_registry() {
  local p="$1/${PLANS_SYSTEMS_FILE}"
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

# ---------- --version (alias of bare invocation) ----------
#
# `x-x` and `x-x --version` share runDefault: same notice output, same
# lazy bootstrap of ~/.x-x/agents/ on first run, same 24h update check.
# Keeping the assertion symmetric with the bare case pins that both
# entry points stay aligned even after future refactors.

case_start "x-x --version prints notice and bootstraps agents"
reset_user_home
run_capture "" --version
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "version line" "$RUN_OUT" "x-x by Stackific, ${E2E_VERSION}"
assert_not_contains "no usage block" "$RUN_OUT" "Usage:"
assert_is_dir "lazy-bootstrap agents dir" "$HOME/${XX_AGENTS_DIR}"
assert_is_dir "lazy-bootstrap skill ${SKILL_X_X_DIR}" \
  "$HOME/${XX_AGENTS_SKILLS_DIR}/${SKILL_X_X_DIR}"

# ---------- -h / --help ----------

case_start "x-x -h prints notice + usage"
reset_user_home
run_capture "" -h
assert_eq "exit 0" "$RUN_RC" "0"
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "usage header"        "$combined" "Usage:"
assert_contains "init listed"         "$combined" "x-x init"
assert_not_contains "no bootstrap"    "$combined" "x-x bootstrap"
assert_contains "skill remove user"   "$combined" "x-x skills remove --user"
assert_contains "skill remove proj"   "$combined" "x-x skills remove --project"
assert_contains "plan next-prefix"    "$combined" "x-x plans next-prefix"
assert_contains "plan list"           "$combined" "x-x plans list"
assert_contains "plan lint"           "$combined" "x-x plans lint"
assert_contains "plan slugify"        "$combined" "x-x plans slugify"
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
assert_contains "git-commit tip" "$RUN_OUT" "commit ${PLANS_DIR}/ to git"
for base in "${CLAUDE_SKILLS_REL}" "${CODEX_SKILLS_REL}"; do
  for skill in $OWNED_SKILLS; do
    assert_is_dir "project $base/$skill" "$PROJ/$base/$skill"
  done
done
assert_is_file "project ${CLAUDE_SETTINGS_PATH}" "$PROJ/${CLAUDE_SETTINGS_PATH}"
assert_is_file "project ${CODEX_HOOKS_PATH}"     "$PROJ/${CODEX_HOOKS_PATH}"
assert_is_file "${PLANS_LOCK_PATH} written"       "$PROJ/${PLANS_LOCK_PATH}"
assert_is_file "${PLANS_SYSTEMS_PATH} written"    "$PROJ/${PLANS_SYSTEMS_PATH}"
assert_contains "${PLANS_LOCK_PATH} has prefix_width" \
  "$(cat "$PROJ/${PLANS_LOCK_PATH}")" "\"prefix_width\": ${DEFAULT_PREFIX_WIDTH}"
assert_contains "${PLANS_LOCK_PATH} has review_per" \
  "$(cat "$PROJ/${PLANS_LOCK_PATH}")" "\"review_per\": \"task\""
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
# init now has FIVE interactive questions: agents → scope → prefix-width
# → max-plan-lines → plan-review-per. Each pipe below answers them in
# that order; blank lines accept the prompt's default (all agents for
# the multi-select, the project default for the three plan-tooling
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

case_start "x-x init interactive (default agents + project scope)"
reset_user_home
PROJ_INT="$(fresh_project)"
cd "$PROJ_INT"
# agents=default, scope=project, prefix-width=default, max-lines=default, review=default.
run_capture "
1



" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_is_dir  "interactive project skill" "$PROJ_INT/${CLAUDE_SKILLS_REL}/${SKILL_X_X_DIR}"
assert_is_file "interactive plan lock"     "$PROJ_INT/${PLANS_LOCK_PATH}"
assert_contains "interactive lock keeps default prefix_width" \
  "$(cat "$PROJ_INT/${PLANS_LOCK_PATH}")" "\"prefix_width\": ${DEFAULT_PREFIX_WIDTH}"

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

case_start "x-x init interactive (custom prefix-width + max-plan-lines + review)"
reset_user_home
PROJ_INT3="$(fresh_project)"
cd "$PROJ_INT3"
# agents=default, scope=project, prefix=6, max=42, review=2 (plan).
run_capture "
1
6
42
2
" init
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "interactive lock honors custom prefix_width" \
  "$(cat "$PROJ_INT3/${PLANS_LOCK_PATH}")" "\"prefix_width\": 6"
assert_contains "interactive lock honors custom max_plan_lines" \
  "$(cat "$PROJ_INT3/${PLANS_LOCK_PATH}")" "\"max_plan_lines\": 42"
assert_contains "interactive lock honors custom review_per" \
  "$(cat "$PROJ_INT3/${PLANS_LOCK_PATH}")" "\"review_per\": \"plan\""

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
assert_contains "diagnostic on stderr" "$RUN_ERR" "invalid"

case_start "x-x init interactive (invalid prefix-width)"
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

# ---------- init plan-tooling flag twins (--prefix-width / --max-plan-lines / --review-per) ----------
#
# All five prompts have flag twins; passing every flag drives runInit
# end-to-end without ever touching stdin (true non-interactive). Each
# case below pins the wire-format of `_config.lock` so any drift between
# the flag values and what lands on disk fails loud.

case_start "x-x init --prefix-width / --max-plan-lines / --review-per (all flags)"
reset_user_home
PROJ_FF="$(fresh_project)"
cd "$PROJ_FF"
run_capture "" init --scope project --agents=claude,codex \
  --prefix-width=6 --max-plan-lines=42 --review-per=plan
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "lock honors --prefix-width" \
  "$(cat "$PROJ_FF/${PLANS_LOCK_PATH}")" "\"prefix_width\": 6"
assert_contains "lock honors --max-plan-lines" \
  "$(cat "$PROJ_FF/${PLANS_LOCK_PATH}")" "\"max_plan_lines\": 42"
assert_contains "lock honors --review-per" \
  "$(cat "$PROJ_FF/${PLANS_LOCK_PATH}")" "\"review_per\": \"plan\""

case_start "x-x init --review-per=task (explicit default)"
reset_user_home
PROJ_FT="$(fresh_project)"
cd "$PROJ_FT"
run_capture "" init --scope project --agents=claude --prefix-width=4 \
  --max-plan-lines=30 --review-per=task
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "lock honors --review-per=task" \
  "$(cat "$PROJ_FT/${PLANS_LOCK_PATH}")" "\"review_per\": \"task\""

case_start "x-x init --review-per invalid"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project --agents=claude --prefix-width=4 \
  --max-plan-lines=30 --review-per=commit
[ "$RUN_RC" != "0" ] && ok "non-zero exit" || fail "non-zero exit"
assert_contains "diagnostic" "$RUN_ERR" "invalid --review-per"

case_start "x-x init --prefix-width=-1 rejected"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project --agents=claude --prefix-width=-1 \
  --max-plan-lines=30 --review-per=task
[ "$RUN_RC" != "0" ] && ok "non-zero exit" || fail "non-zero exit"
assert_contains "diagnostic" "$RUN_ERR" "--prefix-width must be positive"

case_start "x-x init --max-plan-lines=0 rejected"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope project --agents=claude --prefix-width=4 \
  --max-plan-lines=0 --review-per=task
[ "$RUN_RC" != "0" ] && ok "non-zero exit" || fail "non-zero exit"
assert_contains "diagnostic" "$RUN_ERR" "--max-plan-lines must be positive"

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

case_start "x-x skills(no subcommand)"
run_capture "" skills
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: x-x skills <subcommand>"

case_start "x-x skills <typo>"
run_capture "" skills frobnicate
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "unknown skills subcommand: frobnicate"

# ---------- skill remove (no flag) ----------

case_start "x-x skills remove (no flag)"
run_capture "" skills remove
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: x-x skills remove"

# ---------- skill remove --user + --project (mutex) ----------

case_start "x-x skills remove --user --project (mutex)"
run_capture "" skills remove --user --project
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "mutually exclusive"

# ---------- skill remove --user (end-to-end) ----------

case_start "x-x skills remove --user"
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

case_start "x-x skills remove --project"
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
assert_is_file "${PLANS_LOCK_PATH} preserved"       "$PROJ_RM/${PLANS_LOCK_PATH}"
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
#   - Plan-tooling lock file (non-bundled, written by writePlanScaffold)
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
# Documented re-init flow: delete the lock to unblock the project-gate
# refusal. The lock will be re-written by init from the wizard/flag
# choices for this run.
rm "$PROJ_RE/${PLANS_LOCK_PATH}"
run_capture "" init --scope project
assert_eq "exit 0" "$RUN_RC" "0"
CLAUDE_BODY="$(cat "$PROJ_RE/${CLAUDE_SETTINGS_PATH}")"
CODEX_BODY="$(cat "$PROJ_RE/${CODEX_HOOKS_PATH}")"
assert_contains "${CLAUDE_SETTINGS_FILE} keeps user key"   "$CLAUDE_BODY" '"USER": "EDIT"'
assert_contains "${CLAUDE_SETTINGS_FILE} keeps user model" "$CLAUDE_BODY" '"model": "sonnet"'
assert_contains "${CLAUDE_SETTINGS_FILE} gains fastMode"   "$CLAUDE_BODY" '"fastMode": true'
assert_contains "${CLAUDE_SETTINGS_FILE} gains hook"       "$CLAUDE_BODY" 'x-x plans lint'
assert_contains "${CODEX_HOOKS_FILE} keeps user key"       "$CODEX_BODY"  '"USER": "EDIT"'
assert_contains "${CODEX_HOOKS_FILE} gains hook"           "$CODEX_BODY"  'x-x plans lint'

# ---------- merge is idempotent: a second re-run is a byte-level no-op ----------

case_start "init re-run is idempotent on merged ${CLAUDE_SETTINGS_FILE}"
reset_user_home
PROJ_IDEM_JSON="$(fresh_project)"
cd "$PROJ_IDEM_JSON"
run_capture "" init --scope project
echo '{"model": "sonnet"}' > "$PROJ_IDEM_JSON/${CLAUDE_SETTINGS_PATH}"
echo '{"model": "sonnet"}' > "$PROJ_IDEM_JSON/${CODEX_HOOKS_PATH}"
# First re-run materializes the merged shape. Lock-delete is the
# documented gate-bypass; init recreates it from this run's choices.
rm "$PROJ_IDEM_JSON/${PLANS_LOCK_PATH}"
run_capture "" init --scope project
SNAP_CLAUDE_1="$(cat "$PROJ_IDEM_JSON/${CLAUDE_SETTINGS_PATH}")"
SNAP_CODEX_1="$(cat "$PROJ_IDEM_JSON/${CODEX_HOOKS_PATH}")"
# Second re-run must be a byte-level no-op — array-union dedup catches
# every bundled entry already present from the first merge.
rm "$PROJ_IDEM_JSON/${PLANS_LOCK_PATH}"
run_capture "" init --scope project
SNAP_CLAUDE_2="$(cat "$PROJ_IDEM_JSON/${CLAUDE_SETTINGS_PATH}")"
SNAP_CODEX_2="$(cat "$PROJ_IDEM_JSON/${CODEX_HOOKS_PATH}")"
assert_eq "${CLAUDE_SETTINGS_FILE} idempotent" "$SNAP_CLAUDE_1" "$SNAP_CLAUDE_2"
assert_eq "${CODEX_HOOKS_FILE} idempotent"     "$SNAP_CODEX_1"  "$SNAP_CODEX_2"

# ---------- merge: user scalar wins on a conflict ----------
#
# `fastMode: false` is the canonical "I opted OUT" choice. A bundled
# `fastMode: true` must NEVER flip the user's explicit `false`. Bundled
# object keys missing from the existing file still land (the `hooks`
# object below) — only the conflicting scalar is left alone.

case_start "init re-run merge: user scalar wins (fastMode: false)"
reset_user_home
PROJ_SCALAR="$(fresh_project)"
cd "$PROJ_SCALAR"
run_capture "" init --scope project
echo '{"fastMode": false}' > "$PROJ_SCALAR/${CLAUDE_SETTINGS_PATH}"
rm "$PROJ_SCALAR/${PLANS_LOCK_PATH}"
run_capture "" init --scope project
SCALAR_BODY="$(cat "$PROJ_SCALAR/${CLAUDE_SETTINGS_PATH}")"
assert_contains "user fastMode=false preserved" "$SCALAR_BODY" '"fastMode": false'
assert_not_contains "bundled fastMode=true rejected" "$SCALAR_BODY" '"fastMode": true'
assert_contains    "bundled hooks still added"       "$SCALAR_BODY" 'x-x plans lint'

# ---------- merge: array entries are unioned, not overwritten ----------
#
# A user-authored hook entry (matcher: Read, calling their own tool) must
# survive AND our bundled Write|Edit|MultiEdit entry must land alongside.
# Both should be present in the resulting PostToolUse array. This is the
# load-bearing case for the merge being additive on arrays.

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
rm "$PROJ_ARR/${PLANS_LOCK_PATH}"
run_capture "" init --scope project
ARR_BODY="$(cat "$PROJ_ARR/${CLAUDE_SETTINGS_PATH}")"
assert_contains "user matcher Read survives"      "$ARR_BODY" '"matcher": "Read"'
assert_contains "user command my-tool survives"   "$ARR_BODY" '"command": "my-tool"'
assert_contains "bundled matcher Write|Edit|MultiEdit lands" "$ARR_BODY" '"matcher": "Write|Edit|MultiEdit"'
assert_contains "bundled command x-x plans lint lands" "$ARR_BODY" '"command": "x-x plans lint"'

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
rm "$PROJ_BAD/${PLANS_LOCK_PATH}"
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
rm "$PROJ_EMPTY/${PLANS_LOCK_PATH}"
run_capture "" init --scope project
EMPTY_BODY="$(cat "$PROJ_EMPTY/${CLAUDE_SETTINGS_PATH}")"
assert_contains "empty file gained fastMode" "$EMPTY_BODY" '"fastMode": true'
assert_contains "empty file gained hook"     "$EMPTY_BODY" 'x-x plans lint'

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
rm "$PROJ_SIB/${PLANS_LOCK_PATH}"
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
  "${PLANS_LOCK_PATH}" \
  "${PLANS_SYSTEMS_PATH}"; do
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
# shape, update this fixture in lockstep — drift surfaces as an assertion
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
      {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "x-x plans lint"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "USER-HOOK"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "x-x plans lint"}]}
    ]
  }
}
EOF
cat > "$PROJ_UN/${CODEX_HOOKS_PATH}" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "apply_patch", "hooks": [{"type": "command", "command": "x-x plans lint"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "x-x plans lint 1>&2"}]},
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
assert_not_contains "claude bundled command gone"      "$CLAUDE_BODY" 'x-x plans lint'
assert_not_contains "codex apply_patch matcher gone"   "$CODEX_BODY"  'apply_patch'
assert_not_contains "codex Stop bundled command gone"  "$CODEX_BODY"  'x-x plans lint 1>&2'

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
      {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "x-x plans lint --verbose"}]}
    ]
  }
}
EOF
run_capture "" skills remove --project
assert_eq "exit 0" "$RUN_RC" "0"
TWEAKED_BODY="$(cat "$PROJ_UNT/${CLAUDE_SETTINGS_PATH}")"
assert_contains "tweaked matcher kept" "$TWEAKED_BODY" 'Write|Edit|MultiEdit'
assert_contains "tweaked command kept" "$TWEAKED_BODY" 'x-x plans lint --verbose'

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

case_start "init --scope user re-run merges edited ${CLAUDE_SETTINGS_FILE} + ${CODEX_HOOKS_FILE}"
reset_user_home
PROJ_USER_MERGE="$(fresh_project)"
cd "$PROJ_USER_MERGE"
run_capture "" init --scope user
echo '{"USER": "EDIT"}' > "$HOME/${CLAUDE_SETTINGS_PATH}"
echo '{"USER": "EDIT"}' > "$HOME/${CODEX_HOOKS_PATH}"
# Even under --scope user, init writes .x-plans/ into cwd — the project
# gate is keyed on the cwd-local lock regardless of skill scope.
rm "$PROJ_USER_MERGE/${PLANS_LOCK_PATH}"
run_capture "" init --scope user
assert_eq "exit 0" "$RUN_RC" "0"
USER_CLAUDE_BODY="$(cat "$HOME/${CLAUDE_SETTINGS_PATH}")"
USER_CODEX_BODY="$(cat "$HOME/${CODEX_HOOKS_PATH}")"
# Same contract as the project-scope merge case, but the destination is
# under $HOME (user-scope install). User key survives + bundle keys land.
assert_contains "user ${CLAUDE_SETTINGS_FILE} keeps user key" "$USER_CLAUDE_BODY" '"USER": "EDIT"'
assert_contains "user ${CLAUDE_SETTINGS_FILE} gains fastMode" "$USER_CLAUDE_BODY" '"fastMode": true'
assert_contains "user ${CLAUDE_SETTINGS_FILE} gains hook"     "$USER_CLAUDE_BODY" 'x-x plans lint'
assert_contains "user ${CODEX_HOOKS_FILE} keeps user key"     "$USER_CODEX_BODY"  '"USER": "EDIT"'
assert_contains "user ${CODEX_HOOKS_FILE} gains hook"         "$USER_CODEX_BODY"  'x-x plans lint'

# ---------- isolation: init --scope user re-run keeps sibling skills ----------

case_start "init --scope user re-run keeps user-authored sibling skills"
reset_user_home
PROJ_USER_SIB="$(fresh_project)"
cd "$PROJ_USER_SIB"
run_capture "" init --scope user
mkdir -p "$HOME/${CLAUDE_SKILLS_REL}/my-custom"
echo "MINE" > "$HOME/${CLAUDE_SKILLS_REL}/my-custom/SKILL.md"
rm "$PROJ_USER_SIB/${PLANS_LOCK_PATH}"
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
run_capture "" skills remove --user
assert_eq "exit 0 on empty state" "$RUN_RC" "0"
assert_contains "summary line" "$RUN_OUT" "Removed 0"

case_start "skill remove --project outside an x-x project"
reset_user_home
cd "$(fresh_project)"
run_capture "" skills remove --project
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not an x-x project"
assert_contains "hint"       "$RUN_ERR" "x-x init"

case_start "skill remove --project is a silent no-op when only the scaffold exists"
reset_user_home
PROJ_RM_EMPTY="$(fresh_project)"
seed_project_scaffold "$PROJ_RM_EMPTY"
cd "$PROJ_RM_EMPTY"
run_capture "" skills remove --project
assert_eq "exit 0 on empty state" "$RUN_RC" "0"
assert_contains "summary line" "$RUN_OUT" "Removed 0"

# ---------- idempotency: re-running has zero net effect ----------

case_start "bare x-x is idempotent (no re-bootstrap)"
reset_user_home
run_capture ""
sentinel_path="$HOME/${XX_AGENTS_SKILLS_DIR}/${SKILL_X_X_DIR}/SKILL.md"
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
run_capture ""
second_mtime="$(read_mtime "$sentinel_path")"
assert_eq "mtime unchanged across runs" "$first_mtime" "$second_mtime"

case_start "init refuses re-run on an initialized project (lock-file marker)"
reset_user_home
PROJ_IDEM="$(fresh_project)"
cd "$PROJ_IDEM"
run_capture "" init --scope project
assert_eq "first init exit 0" "$RUN_RC" "0"
assert_exists "lock written" "$PROJ_IDEM/${PLANS_LOCK_PATH}"
# Seed the systems registry with content so we can later verify init
# never overwrites it on the post-lock-deletion re-run.
echo "systems:" > "$PROJ_IDEM/${PLANS_SYSTEMS_PATH}"
echo "  - name: payments" >> "$PROJ_IDEM/${PLANS_SYSTEMS_PATH}"
systems_before="$(cat "$PROJ_IDEM/${PLANS_SYSTEMS_PATH}")"
run_capture "" init --scope project
assert_eq "second init refused (exit 2)" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "already initialized"
assert_contains "hint mentions ${PLANS_CONFIG_LOCK}" "$RUN_ERR" "${PLANS_CONFIG_LOCK}"

case_start "init re-runs after lock file deletion, preserving ${PLANS_SYSTEMS_FILE}"
rm "$PROJ_IDEM/${PLANS_LOCK_PATH}"
run_capture "" init --scope project
assert_eq "exit 0 after lock removed" "$RUN_RC" "0"
assert_exists "lock recreated" "$PROJ_IDEM/${PLANS_LOCK_PATH}"
systems_after="$(cat "$PROJ_IDEM/${PLANS_SYSTEMS_PATH}")"
assert_eq "${PLANS_SYSTEMS_FILE} untouched across re-init" "$systems_before" "$systems_after"

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

# ---------- shared-doc resolution invariants ----------
#
# Both shipped SKILL.md files (x-x, x-plan) tell readers that shared
# `_x-x_shared/*.md` files live under both `.claude/skills/` and
# `.agents/skills/` at project and user scope, with "project scope first,
# then user scope" as the resolution order. The binary doesn't implement
# that resolution — Claude Code / Codex CLI do — but the install layout
# has to *support* it. These cases pin every observable property the rule
# depends on.
#
# The three shared files the docs actually reference by basename.
# Composed from the mirrored constants so the next rename only touches
# constants.go + the shell mirror — never the case bodies below.
readonly SHARED_DOC_FILES="${SHARED_DOC_PLAN_FIRST} ${SHARED_DOC_SYSTEMS} ${SHARED_DOC_EARS}"
# The bundled-source path under the repo, joined here so call sites stay flat.
readonly SHARED_BUNDLE_DIR="${REPO_ROOT}/${AGENTS_EMBED_ROOT}/${SKILLS_SUBDIR}/${SKILL_SHARED_DIR}"

case_start "shared docs land at both agent roots under project scope"
reset_user_home
PROJ_SD1="$(fresh_project)"
cd "$PROJ_SD1"
run_capture "" init --scope=project --agents=claude,codex
assert_eq "init exit 0" "$RUN_RC" "0"
for fname in $SHARED_DOC_FILES; do
  assert_is_file "project Claude has $fname" \
    "$PROJ_SD1/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}"
  assert_is_file "project Codex has $fname" \
    "$PROJ_SD1/${CODEX_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}"
done

case_start "shared docs land at both agent roots under user scope"
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope=user --agents=claude,codex
assert_eq "init exit 0" "$RUN_RC" "0"
for fname in $SHARED_DOC_FILES; do
  # User-scope installs are symlinks on macOS/Linux; assert through the
  # link by checking the resolved file exists.
  assert_exists "user Claude has $fname (via symlink)" \
    "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}"
  assert_exists "user Codex has $fname (via symlink)" \
    "$HOME/${CODEX_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}"
done

case_start "shared docs are byte-identical across Claude and Codex roots"
# Reuses PROJ_SD1 from the project-scope case above. At project scope the
# two copies are independent file writes; equal bytes proves the embed
# walk wrote the same content to both destinations.
for fname in $SHARED_DOC_FILES; do
  claude_sha="$(sha256_of "$PROJ_SD1/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}")"
  codex_sha="$(sha256_of  "$PROJ_SD1/${CODEX_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}")"
  assert_eq "project $fname Claude≡Codex sha256" "$claude_sha" "$codex_sha"
done
# Same property at user scope. Both sides symlink into ~/.x-x/agents/,
# so the digests collapse onto the single bundled source — still a useful
# invariant: if init ever started copying instead of linking, byte drift
# would be the first thing we'd see.
for fname in $SHARED_DOC_FILES; do
  claude_sha="$(sha256_of "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}")"
  codex_sha="$(sha256_of  "$HOME/${CODEX_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}")"
  assert_eq "user $fname Claude≡Codex sha256" "$claude_sha" "$codex_sha"
done

case_start "installed shared docs match the embed source byte-for-byte"
# Pins that `x-x init` doesn't mutate content on the way out — the file
# the user reads is the file the binary was built with.
for fname in $SHARED_DOC_FILES; do
  bundle_sha="$(sha256_of "${SHARED_BUNDLE_DIR}/${fname}")"
  proj_sha="$(sha256_of   "$PROJ_SD1/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}")"
  user_sha="$(sha256_of   "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}")"
  assert_eq "$fname project ≡ embed sha256" "$proj_sha" "$bundle_sha"
  assert_eq "$fname user ≡ embed sha256"    "$user_sha" "$bundle_sha"
done

case_start "resolution-rule paragraph is present at every install location"
# Anchor phrase chosen to be specific enough that random doc edits don't
# accidentally satisfy it. The rule now lives in each SKILL.md (not in
# the shared file itself), so scan both SKILL.md files at every install
# root. If the rule is removed from either, this fails.
readonly RESOLUTION_ANCHOR="Check project scope first, then user scope"
for root in \
  "$PROJ_SD1/${CLAUDE_SKILLS_REL}" \
  "$PROJ_SD1/${CODEX_SKILLS_REL}" \
  "$HOME/${CLAUDE_SKILLS_REL}" \
  "$HOME/${CODEX_SKILLS_REL}"; do
  for skill in "${SKILL_X_X_DIR}" "${SKILL_X_PLAN_DIR}"; do
    body="$(cat "${root}/${skill}/${SKILL_MANIFEST_FILE}")"
    assert_contains "resolution anchor in ${root}/${skill}" "$body" "$RESOLUTION_ANCHOR"
  done
done

case_start "installed shared/skill docs do not hardcode .claude/skills/_x-x_shared"
# Any reintroduction of a Claude-only path inside the cross-agent docs
# breaks the rule above. Scan every doc the user-facing skills actually
# point at, at every install location.
readonly FORBIDDEN_PATH=".claude/skills/${SKILL_SHARED_DIR}"
docs_to_scan=(
  "${SKILL_SHARED_DIR}/${SHARED_DOC_PLAN_FIRST}"
  "${SKILL_SHARED_DIR}/${SHARED_DOC_SYSTEMS}"
  "${SKILL_SHARED_DIR}/${SHARED_DOC_EARS}"
  "${SKILL_X_X_DIR}/${SKILL_MANIFEST_FILE}"
  "${SKILL_X_PLAN_DIR}/${SKILL_MANIFEST_FILE}"
)
for root in \
  "$PROJ_SD1/${CLAUDE_SKILLS_REL}" \
  "$PROJ_SD1/${CODEX_SKILLS_REL}" \
  "$HOME/${CLAUDE_SKILLS_REL}" \
  "$HOME/${CODEX_SKILLS_REL}"; do
  for rel in "${docs_to_scan[@]}"; do
    body="$(cat "${root}/${rel}")"
    assert_not_contains "no hardcoded Claude path in ${root}/${rel}" "$body" "$FORBIDDEN_PATH"
  done
done

case_start "project + user scopes coexist; project copies are not symlinks"
# Run user-scope init from a throwaway cwd (user-scope init still seeds
# `.x-plans/` in whatever directory it was launched from, but we don't
# care about that dir). Then move to a fresh project dir for the
# project-scope init. All four install roots must end up populated, and
# the project-scope copies must be regular files (not symlinks back into
# ~/.x-x/agents/) — otherwise a hand-edit at project scope would
# silently propagate to every other project on the machine.
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope=user   --agents=claude,codex
assert_eq "user init exit 0"    "$RUN_RC" "0"
PROJ_SD7="$(fresh_project)"
cd "$PROJ_SD7"
run_capture "" init --scope=project --agents=claude,codex
assert_eq "project init exit 0" "$RUN_RC" "0"
for fname in $SHARED_DOC_FILES; do
  assert_is_file "project Claude $fname exists"  "$PROJ_SD7/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}"
  assert_is_file "project Codex $fname exists"   "$PROJ_SD7/${CODEX_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}"
  assert_exists  "user Claude $fname exists"     "$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}"
  assert_exists  "user Codex $fname exists"      "$HOME/${CODEX_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}"
  # Project-scope must be a regular file (not a symlink). User-scope is
  # allowed to be a symlink (it's how cross-project refresh propagates).
  [ ! -L "$PROJ_SD7/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}" ] \
    && ok "project Claude $fname is not a symlink" \
    || fail "project Claude $fname is not a symlink" "found symlink — project copy would track user-scope edits"
  [ ! -L "$PROJ_SD7/${CODEX_SKILLS_REL}/${SKILL_SHARED_DIR}/${fname}" ] \
    && ok "project Codex $fname is not a symlink" \
    || fail "project Codex $fname is not a symlink" "found symlink — project copy would track user-scope edits"
done

case_start "project shared-doc edits survive a 24h user-scope refresh"
# Hand-edit a project-scope shared doc with a sentinel byte. Trigger the
# 24h refresh that wholesale-rewrites ~/.x-x/agents/. The project copy
# must retain the sentinel; the user-scope copy (a symlink into the
# refreshed bundled tree) must reflect the embed bytes again.
reset_user_home
cd "$(fresh_project)"
run_capture "" init --scope=user   --agents=claude,codex
PROJ_SD8="$(fresh_project)"
cd "$PROJ_SD8"
run_capture "" init --scope=project --agents=claude,codex
sentinel_doc="$PROJ_SD8/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${SHARED_DOC_PLAN_FIRST}"
printf '\n<!-- e2e sentinel: PROJECT-EDITED -->\n' >> "$sentinel_doc"
# Backdate .config.json so the next bare invocation fires the 24h refresh.
echo "{\"version\":\"${E2E_VERSION}\",\"last_checked\":0}" \
  > "$HOME/${XX_HOME_DIR}/${XX_CONFIG_FILE}"
run_capture ""
assert_eq "bare exit 0" "$RUN_RC" "0"
# Project copy must still contain the sentinel.
project_body="$(cat "$sentinel_doc")"
assert_contains "project sentinel survives refresh" "$project_body" "PROJECT-EDITED"
# User-scope copy (read through the symlink) must be back to the embed
# bytes — no sentinel, original SHA.
user_doc="$HOME/${CLAUDE_SKILLS_REL}/${SKILL_SHARED_DIR}/${SHARED_DOC_PLAN_FIRST}"
user_body="$(cat "$user_doc")"
assert_not_contains "user copy refreshed from embed" "$user_body" "PROJECT-EDITED"
user_sha="$(sha256_of "$user_doc")"
bundle_sha="$(sha256_of "${SHARED_BUNDLE_DIR}/${SHARED_DOC_PLAN_FIRST}")"
assert_eq "user copy ≡ embed sha256 after refresh" "$user_sha" "$bundle_sha"

# ---------- plan next-prefix ----------

case_start "x-x plans(no subcommand)"
run_capture "" plans
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "usage" "$RUN_ERR" "Usage: x-x plans <subcommand>"

case_start "x-x plans <typo>"
run_capture "" plans frobnicate
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "unknown plans subcommand: frobnicate"

case_start "x-x plans next-prefix outside an x-x project"
PROJ_NP="$(fresh_project)"
cd "$PROJ_NP"
run_capture "" plans next-prefix
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not an x-x project"
assert_contains "hint"       "$RUN_ERR" "x-x init"

case_start "x-x plans next-prefix in fresh ${PLANS_DIR} (empty)"
PROJ_NP_EMPTY="$(fresh_project)"
seed_project_scaffold "$PROJ_NP_EMPTY"
cd "$PROJ_NP_EMPTY"
run_capture "" plans next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "first prefix" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "x-x plans next-prefix with default width"
PROJ_NP2="$(fresh_project)"
seed_project_scaffold "$PROJ_NP2"
touch "$PROJ_NP2/${PLANS_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
      "$PROJ_NP2/${PLANS_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-bar.md"
cd "$PROJ_NP2"
run_capture "" plans next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "max+1 default width" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 4)"

case_start "x-x plans next-prefix honors ${PLANS_CONFIG_LOCK} prefix_width"
PROJ_NP3="$(fresh_project)"
seed_project_scaffold "$PROJ_NP3"
custom_width=7
echo "{\"prefix_width\":${custom_width}}" > "$PROJ_NP3/${PLANS_LOCK_PATH}"
touch "$PROJ_NP3/${PLANS_DIR}/$(prefix "$custom_width" 41)-foo.md"
cd "$PROJ_NP3"
run_capture "" plans next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "custom width applied" "$RUN_OUT" "$(prefix "$custom_width" 42)"

case_start "x-x plans next-prefix rejects positional arg"
cd "$(fresh_project)"
run_capture "" plans next-prefix some/dir
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no arguments"

case_start "x-x plans next-prefix ignores non-matching filenames"
PROJ_NP4="$(fresh_project)"
seed_project_scaffold "$PROJ_NP4"
touch "$PROJ_NP4/${PLANS_DIR}/notes.md" \
      "$PROJ_NP4/${PLANS_DIR}/README" \
      "$PROJ_NP4/${PLANS_DIR}/abc-foo.md" \
      "$PROJ_NP4/${PLANS_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 7)-real.md"
cd "$PROJ_NP4"
run_capture "" plans next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "non-matching ignored" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 8)"

case_start "x-x plans next-prefix with only lock file (no plan files)"
PROJ_NP5="$(fresh_project)"
seed_project_scaffold "$PROJ_NP5"
echo "{\"prefix_width\":${DEFAULT_PREFIX_WIDTH}}" > "$PROJ_NP5/${PLANS_LOCK_PATH}"
cd "$PROJ_NP5"
run_capture "" plans next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "lock-only → first prefix" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "x-x plans next-prefix falls back to default width on malformed lock"
PROJ_NP6="$(fresh_project)"
seed_project_scaffold "$PROJ_NP6"
echo '{not json' > "$PROJ_NP6/${PLANS_LOCK_PATH}"
cd "$PROJ_NP6"
run_capture "" plans next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "default width on bad lock" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "x-x plans next-prefix falls back to default width on zero prefix_width"
PROJ_NP7="$(fresh_project)"
seed_project_scaffold "$PROJ_NP7"
echo '{"prefix_width":0}' > "$PROJ_NP7/${PLANS_LOCK_PATH}"
cd "$PROJ_NP7"
run_capture "" plans next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "default width on zero" "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)"

case_start "x-x plans next-prefix rolls past width digits"
PROJ_NP8="$(fresh_project)"
seed_project_scaffold "$PROJ_NP8"
# Seed with a prefix that exactly fills DEFAULT_PREFIX_WIDTH (all 9s), so
# incrementing it overflows the digit budget. With width=4 that's 9999;
# bump the seed when the constant changes.
seed_overflow="$(printf '%0*d' "$DEFAULT_PREFIX_WIDTH" 0 | tr '0' '9')"
overflow_next="$((10 ** DEFAULT_PREFIX_WIDTH))"
touch "$PROJ_NP8/${PLANS_DIR}/${seed_overflow}-last.md"
cd "$PROJ_NP8"
run_capture "" plans next-prefix
assert_eq "exit 0" "$RUN_RC" "0"
# fmt.Printf("%0*d", width, n) does not truncate when n already has
# more digits than width — so 9999+1 prints as "10000" at width 4.
assert_eq "overflow keeps counting" "$RUN_OUT" "$overflow_next"

# ---------- plan list ----------

case_start "x-x plans list (empty ${PLANS_DIR})"
PROJ_PL1="$(fresh_project)"
seed_project_scaffold "$PROJ_PL1"
cd "$PROJ_PL1"
run_capture "" plans list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "no rows on empty" "$RUN_OUT" ""

case_start "x-x plans list outside an x-x project"
PROJ_PL2="$(fresh_project)"
cd "$PROJ_PL2"
run_capture "" plans list
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not an x-x project"
assert_contains "hint"       "$RUN_ERR" "x-x init"

case_start "x-x plans list emits tab-separated rows sorted by prefix descending (default)"
PROJ_PL3="$(fresh_project)"
seed_project_scaffold "$PROJ_PL3"
write_plan "$PROJ_PL3/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-bravo.md"   "deprecated" "billing"
write_plan "$PROJ_PL3/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md"   "valid"      "auth, billing"
write_plan "$PROJ_PL3/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-charlie.md" "superseded" "auth"
cd "$PROJ_PL3"
run_capture "" plans list
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-charlie\tsuperseded\tauth\n%s-bravo\tdeprecated\tbilling\n%s-alpha\tvalid\tauth,billing' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"
assert_eq "desc tab-separated rows" "$RUN_OUT" "$expected"

case_start "x-x plans list --order=asc reverses to prefix-ascending"
cd "$PROJ_PL3"
run_capture "" plans list --order=asc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-alpha\tvalid\tauth,billing\n%s-bravo\tdeprecated\tbilling\n%s-charlie\tsuperseded\tauth' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)")"
assert_eq "asc tab-separated rows" "$RUN_OUT" "$expected"

case_start "x-x plans list --order=desc (explicit default)"
cd "$PROJ_PL3"
run_capture "" plans list --order=desc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-charlie\tsuperseded\tauth\n%s-bravo\tdeprecated\tbilling\n%s-alpha\tvalid\tauth,billing' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"
assert_eq "explicit desc tab-separated rows" "$RUN_OUT" "$expected"

case_start "x-x plans list --order=bogus rejected"
cd "$PROJ_PL3"
run_capture "" plans list --order=bogus
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "--order must be"

case_start "x-x plans list --status filters"
cd "$PROJ_PL3"
run_capture "" plans list --status valid
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "status filter keeps only valid" "$RUN_OUT" \
  "$(printf '%s-alpha\tvalid\tauth,billing' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "x-x plans list --status comma list (desc order)"
cd "$PROJ_PL3"
run_capture "" plans list --status valid,superseded
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-charlie\tsuperseded\tauth\n%s-alpha\tvalid\tauth,billing' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"
assert_eq "comma status filter (desc)" "$RUN_OUT" "$expected"

case_start "x-x plans list --system OR semantics (desc order)"
cd "$PROJ_PL3"
run_capture "" plans list --system billing
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-bravo\tdeprecated\tbilling\n%s-alpha\tvalid\tauth,billing' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"
assert_eq "system filter matches any (desc)" "$RUN_OUT" "$expected"

case_start "x-x plans list combined --status and --system"
cd "$PROJ_PL3"
run_capture "" plans list --status valid --system auth
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "status+system intersection" "$RUN_OUT" \
  "$(printf '%s-alpha\tvalid\tauth,billing' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "x-x plans list warns on malformed frontmatter but keeps siblings"
PROJ_PL4="$(fresh_project)"
seed_project_scaffold "$PROJ_PL4"
broken_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-broken.md"
ok_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-ok.md"
echo "not a plan" > "$PROJ_PL4/${PLANS_DIR}/$broken_name"
write_plan "$PROJ_PL4/${PLANS_DIR}" "$ok_name" "valid" "auth"
cd "$PROJ_PL4"
run_capture "" plans list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "broken skipped, ok kept" "$RUN_OUT" \
  "$(printf '%s\tvalid\tauth' "${ok_name%.md}")"
assert_contains "warning to stderr" "$RUN_ERR" "$broken_name"

case_start "x-x plans list ignores non-matching filenames"
PROJ_PL5="$(fresh_project)"
seed_project_scaffold "$PROJ_PL5"
keep_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-keep.md"
write_plan "$PROJ_PL5/${PLANS_DIR}" "$keep_name" "valid" "auth"
echo "x" > "$PROJ_PL5/${PLANS_DIR}/README.md"
echo "x" > "$PROJ_PL5/${PLANS_DIR}/123-short.md"
echo "x" > "$PROJ_PL5/${PLANS_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-no-ext"
cd "$PROJ_PL5"
run_capture "" plans list
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "only keep matched" "$RUN_OUT" "$(printf '%s\tvalid\tauth' "${keep_name%.md}")"
[ -z "$RUN_ERR" ] && ok "no spurious warnings" || fail "no spurious warnings" "got: $RUN_ERR"

case_start "x-x plans list rejects positional args"
cd "$(fresh_project)"
run_capture "" plans list foo
assert_eq "exit 2" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no positional"

# ---------- plan list: --system id-aware filter ----------
#
# `--system` matches the kebab `id:` value plans carry in their
# frontmatter `systems:` array. Both sides are id strings — no name
# resolution, no fuzzy match, and `--system` does NOT consult
# `_data_systems.yaml` to validate the requested id (an unknown id
# simply matches zero rows). These cases pin every observable corner
# of the id contract beyond the basic OR semantics covered above.

case_start "x-x plans list --system <kebab-id> matches multi-word system id"
PROJ_PSI1="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI1"
write_plan "$PROJ_PSI1/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md" "valid" "checkout-service"
write_plan "$PROJ_PSI1/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-bravo.md" "valid" "payment-audit-log"
cd "$PROJ_PSI1"
run_capture "" plans list --system checkout-service
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "only checkout-service plan returned" "$RUN_OUT" \
  "$(printf '%s-alpha\tvalid\tcheckout-service' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "x-x plans list --system <unknown-id> returns zero rows silently"
PROJ_PSI2="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI2"
write_plan "$PROJ_PSI2/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md" "valid" "checkout-service"
cd "$PROJ_PSI2"
run_capture "" plans list --system never-declared
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "no rows for unknown id" "$RUN_OUT" ""
[ -z "$RUN_ERR" ] && ok "no stderr noise for unknown id" || fail "no stderr noise for unknown id" "got: $RUN_ERR"

case_start "x-x plans list --system <id> doesn't match display name even when shaped similarly"
# Plan frontmatter id is `checkout-service`; passing the display name
# `Checkout Service` (with space + capitals) must not match. Pins that
# the filter is a literal id string-compare, not a slugify-and-compare.
PROJ_PSI_DN="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI_DN"
write_plan "$PROJ_PSI_DN/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-alpha.md" "valid" "checkout-service"
cd "$PROJ_PSI_DN"
run_capture "" plans list --system "Checkout Service"
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "display name doesn't match kebab id" "$RUN_OUT" ""

case_start "x-x plans list --system <id1>,<id2> OR semantics via comma list"
PROJ_PSI3="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI3"
write_plan "$PROJ_PSI3/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-a.md" "valid" "checkout-service"
write_plan "$PROJ_PSI3/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-b.md" "valid" "payment-audit-log"
write_plan "$PROJ_PSI3/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-c.md" "valid" "other-system"
cd "$PROJ_PSI3"
run_capture "" plans list --system checkout-service,payment-audit-log --order=asc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-a\tvalid\tcheckout-service\n%s-b\tvalid\tpayment-audit-log' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)")"
assert_eq "comma-list OR semantics" "$RUN_OUT" "$expected"

case_start "x-x plans list --system <id1> --system <id2> repeated flag = comma list"
cd "$PROJ_PSI3"
run_capture "" plans list --system checkout-service --system payment-audit-log --order=asc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-a\tvalid\tcheckout-service\n%s-b\tvalid\tpayment-audit-log' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)")"
assert_eq "repeated-flag OR matches comma form" "$RUN_OUT" "$expected"

case_start "x-x plans list --system mixed forms (one comma + one repeat) still OR"
cd "$PROJ_PSI3"
run_capture "" plans list --system checkout-service,other-system --system payment-audit-log --order=asc
assert_eq "exit 0" "$RUN_RC" "0"
expected="$(printf '%s-a\tvalid\tcheckout-service\n%s-b\tvalid\tpayment-audit-log\n%s-c\tvalid\tother-system' \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)" \
  "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)")"
assert_eq "mixed comma+repeat OR" "$RUN_OUT" "$expected"

case_start "x-x plans list --system <id> matches any element of multi-id systems array"
PROJ_PSI4="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI4"
write_plan "$PROJ_PSI4/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-a.md" "valid" "checkout-service, payment-audit-log"
write_plan "$PROJ_PSI4/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-b.md" "valid" "other-system"
cd "$PROJ_PSI4"
run_capture "" plans list --system payment-audit-log
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "single-id flag matches multi-id row" "$RUN_OUT" \
  "$(printf '%s-a\tvalid\tcheckout-service,payment-audit-log' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "x-x plans list combined --status valid --system <id> intersects both"
PROJ_PSI5="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI5"
write_plan "$PROJ_PSI5/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-a.md" "valid"      "checkout-service"
write_plan "$PROJ_PSI5/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-b.md" "superseded" "checkout-service"
write_plan "$PROJ_PSI5/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-c.md" "valid"      "other-system"
cd "$PROJ_PSI5"
run_capture "" plans list --status valid --system checkout-service
assert_eq "exit 0" "$RUN_RC" "0"
assert_eq "status+id intersection (single match)" "$RUN_OUT" \
  "$(printf '%s-a\tvalid\tcheckout-service' "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)")"

case_start "x-x plans list --system <id> + --overflow-keywords narrows after id filter"
PROJ_PSI6="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI6"
# Seed enough payment-system plans to cross threshold so overflow engages
# AFTER the --system filter has been applied. Body keyword `retry` then
# narrows further to the one plan whose body mentions retry.
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 5))
for ((i=1; i<=over; i++)); do
  pad="$(printf '%03d' "$i")"
  name="$(prefix "$DEFAULT_PREFIX_WIDTH" "$i")-plan${pad}.md"
  cat > "$PROJ_PSI6/${PLANS_DIR}/$name" <<EOF
---
status: valid
systems: [payment-service]
---
${i} generic body
EOF
done
cat > "$PROJ_PSI6/${PLANS_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 7)-plan007.md" <<EOF
---
status: valid
systems: [payment-service]
---
this one is about exponential retry backoff
EOF
# An unrelated plan on a different system; same keyword in body — must be
# gated out by --system before the overflow narrow sees it.
cat > "$PROJ_PSI6/${PLANS_DIR}/$(prefix "$DEFAULT_PREFIX_WIDTH" 99)-unrelated.md" <<EOF
---
status: valid
systems: [unrelated-system]
---
also mentions retry but on a different system
EOF
cd "$PROJ_PSI6"
run_capture "" plans list --system payment-service --overflow-keywords retry
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "plan007 in match"      "$RUN_OUT" "plan007"
assert_not_contains "unrelated gated out before narrow" "$RUN_OUT" "unrelated"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "exactly one match (id ∩ keyword)" "$n" "1"

case_start "x-x plans list --system <id> below threshold makes --overflow-keywords a no-op"
PROJ_PSI7="$(fresh_project)"
seed_project_scaffold "$PROJ_PSI7"
write_plan "$PROJ_PSI7/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-a.md" "valid" "checkout-service"
write_plan "$PROJ_PSI7/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-b.md" "valid" "checkout-service"
cd "$PROJ_PSI7"
# Two plans pass --system; the count (2) is well under the threshold, so
# --overflow-keywords engages no matter what we pass.
run_capture "" plans list --system checkout-service --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "both rows pass through (threshold not exceeded)" "$n" "2"

# ---------- plan list: --overflow-keywords + threshold behavior ----------
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
# ${PLANS_LIST_OVERFLOW_THRESHOLD}.

case_start "x-x plans list with exactly threshold rows ignores --overflow-keywords"
PROJ_OK1="$(fresh_project)"
seed_project_scaffold "$PROJ_OK1"
seed_many_plans "$PROJ_OK1/${PLANS_DIR}" "${PLANS_LIST_OVERFLOW_THRESHOLD}" "payment retry"
cd "$PROJ_OK1"
run_capture "" plans list --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
ok_count="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "all ${PLANS_LIST_OVERFLOW_THRESHOLD} rows returned (no narrow at threshold)" \
  "$ok_count" "${PLANS_LIST_OVERFLOW_THRESHOLD}"

case_start "x-x plans list with threshold+1 rows + matching keyword narrows to matches"
PROJ_OK2="$(fresh_project)"
seed_project_scaffold "$PROJ_OK2"
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK2/${PLANS_DIR}" "$over" "generic body"
# Overwrite three specific plans' bodies to contain the keyword.
write_plan_body "$PROJ_OK2/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 5)-plan005.md"  "the Payment Service handles charges"
write_plan_body "$PROJ_OK2/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 10)-plan010.md" "PAYMENT pipeline upgrade"
write_plan_body "$PROJ_OK2/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 15)-plan015.md" "deprecated payment flow"
cd "$PROJ_OK2"
run_capture "" plans list --overflow-keywords payment
assert_eq "exit 0" "$RUN_RC" "0"
match_count="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "3 matches returned" "$match_count" "3"
assert_contains "plan005 in matches"  "$RUN_OUT" "plan005"
assert_contains "plan010 in matches"  "$RUN_OUT" "plan010"
assert_contains "plan015 in matches"  "$RUN_OUT" "plan015"

case_start "x-x plans list overflow + no-match falls back to top-threshold rows"
PROJ_OK3="$(fresh_project)"
seed_project_scaffold "$PROJ_OK3"
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 5))
seed_many_plans "$PROJ_OK3/${PLANS_DIR}" "$over" "non-matching body"
cd "$PROJ_OK3"
run_capture "" plans list --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
fb_count="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "fallback returns exactly threshold rows" "$fb_count" "${PLANS_LIST_OVERFLOW_THRESHOLD}"
# Default sort is desc → fallback keeps the highest prefixes (newest).
assert_contains "newest plan in fallback"  "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" "$over")-plan"
assert_not_contains "oldest plan dropped"  "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-plan001"

case_start "x-x plans list overflow without --overflow-keywords returns all rows (no truncation)"
PROJ_OK4="$(fresh_project)"
seed_project_scaffold "$PROJ_OK4"
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 3))
seed_many_plans "$PROJ_OK4/${PLANS_DIR}" "$over" "anything"
cd "$PROJ_OK4"
run_capture "" plans list
assert_eq "exit 0" "$RUN_RC" "0"
all_count="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "all rows returned (caller opted out of narrowing)" "$all_count" "$over"

case_start "x-x plans list overflow + multi-keyword OR semantics"
PROJ_OK5="$(fresh_project)"
seed_project_scaffold "$PROJ_OK5"
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK5/${PLANS_DIR}" "$over" "irrelevant"
write_plan_body "$PROJ_OK5/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 3)-plan003.md" "talks about checkout"
write_plan_body "$PROJ_OK5/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 7)-plan007.md" "discusses inventory"
write_plan_body "$PROJ_OK5/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 9)-plan009.md" "covers shipping logistics"
cd "$PROJ_OK5"
run_capture "" plans list --overflow-keywords checkout,inventory
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "OR matches both terms" "$n" "2"
assert_contains "plan003 (checkout)"  "$RUN_OUT" "plan003"
assert_contains "plan007 (inventory)" "$RUN_OUT" "plan007"
assert_not_contains "plan009 not matched" "$RUN_OUT" "plan009"

case_start "x-x plans list overflow + substring match is literal (regex chars not special)"
PROJ_OK6="$(fresh_project)"
seed_project_scaffold "$PROJ_OK6"
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK6/${PLANS_DIR}" "$over" "generic"
write_plan_body "$PROJ_OK6/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 4)-plan004.md" "auth-v1 service"
write_plan_body "$PROJ_OK6/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 8)-plan008.md" "auth-v2 service"
write_plan_body "$PROJ_OK6/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 12)-plan012.md" "auth0 integration"
cd "$PROJ_OK6"
# Plain substring 'auth-v' matches plan004 + plan008 (both contain that
# hyphen) but NOT plan012 (no hyphen). Same behavior with literal regex
# special chars: '.' is a dot, not "any char".
run_capture "" plans list --overflow-keywords 'auth-v'
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "substring matches exactly the two -v rows" "$n" "2"
assert_contains "plan004"  "$RUN_OUT" "plan004"
assert_contains "plan008"  "$RUN_OUT" "plan008"
assert_not_contains "plan012 not matched" "$RUN_OUT" "plan012"
# Confirm regex special chars are literal: a dot in the body must not be
# matched by anything other than a literal dot in the keyword.
write_plan_body "$PROJ_OK6/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 17)-plan017.md" "v1.2.3 release"
run_capture "" plans list --overflow-keywords 'v1.2'
assert_eq "exit 0" "$RUN_RC" "0"
assert_contains "v1.2 (literal dot) hits plan017" "$RUN_OUT" "plan017"

case_start "x-x plans list overflow + frontmatter terms do NOT match (body-only)"
PROJ_OK7="$(fresh_project)"
seed_project_scaffold "$PROJ_OK7"
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK7/${PLANS_DIR}" "$over" "body content"
cd "$PROJ_OK7"
# "auth" is in every plan's frontmatter `systems:` (the kebab id) but
# never in body. Keyword search is body-only → no matches → top-threshold
# fallback. The capitalized `Auth` keyword would not match either; the
# real point is that frontmatter scalars (whatever their case) never feed
# the body-only narrow.
run_capture "" plans list --overflow-keywords Auth
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "frontmatter doesn't match → fallback to top-threshold" "$n" "${PLANS_LIST_OVERFLOW_THRESHOLD}"

case_start "x-x plans list overflow + --status filter narrows below threshold first"
PROJ_OK8="$(fresh_project)"
seed_project_scaffold "$PROJ_OK8"
# Seed 25 plans, mark 3 as "deprecated" — --status filter will reduce
# the post-status set to 3, far below threshold, so overflow-keywords
# never engages.
seed_many_plans "$PROJ_OK8/${PLANS_DIR}" 25 "body"
# Flip three plans to deprecated.
for n in 5 10 15; do
  pad="$(printf '%03d' "$n")"
  name="$(prefix "$DEFAULT_PREFIX_WIDTH" "$n")-plan${pad}.md"
  sed -i.bak -e 's/^status: valid$/status: deprecated/' "$PROJ_OK8/${PLANS_DIR}/$name"
  rm -f "$PROJ_OK8/${PLANS_DIR}/$name.bak"
done
cd "$PROJ_OK8"
run_capture "" plans list --status deprecated --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "3 deprecated rows pass through ungrep" "$n" "3"

case_start "x-x plans list --order=asc preserved through overflow narrow"
PROJ_OK9="$(fresh_project)"
seed_project_scaffold "$PROJ_OK9"
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 1))
seed_many_plans "$PROJ_OK9/${PLANS_DIR}" "$over" "irrelevant"
# Seed two matches, far apart in the sort.
write_plan_body "$PROJ_OK9/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 2)-plan002.md"   "payment thing"
write_plan_body "$PROJ_OK9/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 18)-plan018.md"  "payment thing"
cd "$PROJ_OK9"
run_capture "" plans list --order=asc --overflow-keywords payment
assert_eq "exit 0" "$RUN_RC" "0"
first="$(printf '%s\n' "$RUN_OUT" | head -n1 | awk -F'\t' '{print $1}')"
last="$(printf '%s\n' "$RUN_OUT" | tail -n1 | awk -F'\t' '{print $1}')"
assert_contains "asc: plan002 first"  "$first" "plan002"
assert_contains "asc: plan018 last"   "$last" "plan018"

case_start "x-x plans list overflow + fallback respects --order=asc"
PROJ_OK10="$(fresh_project)"
seed_project_scaffold "$PROJ_OK10"
over=$((PLANS_LIST_OVERFLOW_THRESHOLD + 3))
seed_many_plans "$PROJ_OK10/${PLANS_DIR}" "$over" "irrelevant"
cd "$PROJ_OK10"
run_capture "" plans list --order=asc --overflow-keywords zzz-no-match
assert_eq "exit 0" "$RUN_RC" "0"
# asc fallback returns rows[0..threshold) of asc-sorted list = oldest 20.
first="$(printf '%s\n' "$RUN_OUT" | head -n1 | awk -F'\t' '{print $1}')"
assert_contains "asc fallback starts at plan001"  "$first" "plan001"
assert_not_contains "asc fallback drops newest"   "$RUN_OUT" "$(prefix "$DEFAULT_PREFIX_WIDTH" "$over")-plan"

case_start "x-x plans list overflow + match count above threshold returned in full"
PROJ_OK12="$(fresh_project)"
seed_project_scaffold "$PROJ_OK12"
# 25 plans, ALL match the keyword. The narrow returns 25 (matches are
# not re-truncated — the threshold gates entry to the narrow, not the
# output size).
seed_many_plans "$PROJ_OK12/${PLANS_DIR}" 25 "matches every plan"
cd "$PROJ_OK12"
run_capture "" plans list --overflow-keywords matches
assert_eq "exit 0" "$RUN_RC" "0"
n="$(printf '%s\n' "$RUN_OUT" | grep -c '^.')"
assert_eq "all-match returns all 25" "$n" "25"

# ---------- plan lint ----------

case_start "x-x plans lint outside an x-x project"
PROJ_LN0="$(fresh_project)"
cd "$PROJ_LN0"
run_capture "" plans lint
assert_eq "exit 2 outside project" "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "not an x-x project"
assert_contains "hint"       "$RUN_ERR" "x-x init"

case_start "x-x plans lint happy path"
PROJ_LN1="$(fresh_project)"
seed_project_scaffold "$PROJ_LN1"
write_registry "$PROJ_LN1/${PLANS_DIR}" "Auth Service"
plan1_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
write_full_plan "$PROJ_LN1/${PLANS_DIR}" "$plan1_name" "valid" "auth-service" "Auth Service"
cd "$PROJ_LN1"
run_capture "" plans lint
assert_eq "exit 0"               "$RUN_RC" "0"
assert_contains "ok line"        "$RUN_OUT" "$plan1_name: ok"
assert_contains "summary 1 ok"   "$RUN_ERR" "1 ok, 0 failed"

case_start "x-x plans lint flags bad filename"
PROJ_LN2="$(fresh_project)"
seed_project_scaffold "$PROJ_LN2"
write_registry "$PROJ_LN2/${PLANS_DIR}" "Auth Service"
write_full_plan "$PROJ_LN2/${PLANS_DIR}" "BAD-NAME.md" "valid" "auth-service" "Auth Service"
cd "$PROJ_LN2"
run_capture "" plans lint
assert_eq "exit 1"               "$RUN_RC" "1"
assert_contains "filename finding" "$RUN_OUT" "does not match <prefix>-<slug>.md"

case_start "x-x plans lint flags missing frontmatter"
PROJ_LN3="$(fresh_project)"
seed_project_scaffold "$PROJ_LN3"
write_registry "$PROJ_LN3/${PLANS_DIR}" "Auth Service"
broken_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-broken.md"
echo "just body, no frontmatter" > "$PROJ_LN3/${PLANS_DIR}/$broken_name"
cd "$PROJ_LN3"
run_capture "" plans lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "frontmatter finding" "$RUN_OUT" "missing YAML frontmatter"

case_start "x-x plans lint flags bad status"
PROJ_LN4="$(fresh_project)"
seed_project_scaffold "$PROJ_LN4"
write_registry "$PROJ_LN4/${PLANS_DIR}" "Auth Service"
write_full_plan "$PROJ_LN4/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "bogus" "auth-service" "Auth Service"
cd "$PROJ_LN4"
run_capture "" plans lint
assert_eq "exit 1"           "$RUN_RC" "1"
assert_contains "bad status" "$RUN_OUT" "status \"bogus\" is not one of"

case_start "x-x plans lint flags system not in registry"
PROJ_LN5="$(fresh_project)"
seed_project_scaffold "$PROJ_LN5"
write_registry "$PROJ_LN5/${PLANS_DIR}" "Auth Service"
write_full_plan "$PROJ_LN5/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "valid" "ghost-service" "Ghost Service"
cd "$PROJ_LN5"
run_capture "" plans lint
assert_eq "exit 1"                "$RUN_RC" "1"
assert_contains "system finding"  "$RUN_OUT" "declared system \"ghost-service\" is not in"

case_start "x-x plans lint flags dangling supersedes"
PROJ_LN6="$(fresh_project)"
seed_project_scaffold "$PROJ_LN6"
write_registry "$PROJ_LN6/${PLANS_DIR}" "Auth Service"
super_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN6/${PLANS_DIR}/$super_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "supersedes finding" "$RUN_OUT" "supersedes \"00099-nope\""

case_start "x-x plans lint flags EARS-systems mismatch"
PROJ_LN7="$(fresh_project)"
seed_project_scaffold "$PROJ_LN7"
write_registry "$PROJ_LN7/${PLANS_DIR}" "Auth Service,Billing Service"
# Declares Auth but task names Billing — both diff directions fire.
write_full_plan "$PROJ_LN7/${PLANS_DIR}" "$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md" \
  "valid" "auth-service" "Billing Service"
cd "$PROJ_LN7"
run_capture "" plans lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "EARS-not-in-systems"    "$RUN_OUT" "EARS tasks name systems not in \`systems:\`"
assert_contains "systems-not-in-tasks"   "$RUN_OUT" "\`systems:\` declares systems not used in any EARS task"

case_start "x-x plans lint rejects positional arg"
cd "$(fresh_project)"
run_capture "" plans lint somearg
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "takes no arguments"

case_start "x-x plans lint flags missing title"
PROJ_LN_TT="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_TT"
write_registry "$PROJ_LN_TT/${PLANS_DIR}" "Auth Service"
no_title_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_TT/${PLANS_DIR}/$no_title_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"               "$RUN_RC" "1"
assert_contains "title finding"  "$RUN_OUT" "missing required \`title:\`"

case_start "x-x plans lint flags missing created"
PROJ_LN_CR="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_CR"
write_registry "$PROJ_LN_CR/${PLANS_DIR}" "Auth Service"
no_created_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_CR/${PLANS_DIR}/$no_created_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                 "$RUN_RC" "1"
assert_contains "created finding"  "$RUN_OUT" "missing required \`created:\`"

case_start "x-x plans lint flags malformed created"
PROJ_LN_CD="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_CD"
write_registry "$PROJ_LN_CD/${PLANS_DIR}" "Auth Service"
bad_created_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_CD/${PLANS_DIR}/$bad_created_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "shape finding"     "$RUN_OUT" "is not an ISO 8601 UTC timestamp"

case_start "x-x plans lint flags date-only created (regression for YYYY-MM-DD)"
PROJ_LN_DO="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_DO"
write_registry "$PROJ_LN_DO/${PLANS_DIR}" "Auth Service"
date_only_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_DO/${PLANS_DIR}/$date_only_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "date-only rejected"     "$RUN_OUT" "\"2026-05-23\" is not an ISO 8601 UTC timestamp"

case_start "x-x plans lint flags title-not-first"
PROJ_LN_TO="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_TO"
write_registry "$PROJ_LN_TO/${PLANS_DIR}" "Auth Service"
order_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_LN_TO/${PLANS_DIR}/$order_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"               "$RUN_RC" "1"
assert_contains "order finding"  "$RUN_OUT" "must be the first frontmatter field"

case_start "x-x plans lint flags filename ≠ slugify(title)"
PROJ_LN_FT="$(fresh_project)"
seed_project_scaffold "$PROJ_LN_FT"
write_registry "$PROJ_LN_FT/${PLANS_DIR}" "Auth Service"
mismatch_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
write_full_plan "$PROJ_LN_FT/${PLANS_DIR}" "$mismatch_name" "valid" "auth-service" "Auth Service"
# Overwrite title with one that slugifies to "something-else".
sed -i.bak -e 's/^title: foo/title: Something Else/' "$PROJ_LN_FT/${PLANS_DIR}/$mismatch_name"
rm -f "$PROJ_LN_FT/${PLANS_DIR}/$mismatch_name.bak"
cd "$PROJ_LN_FT"
run_capture "" plans lint
assert_eq "exit 1"                  "$RUN_RC" "1"
assert_contains "filename↔title"    "$RUN_OUT" "does not match slugify(title)"

# ---------- plan lint: id-aware registry + EARS-name resolution ----------
#
# After the registry switched to carrying explicit kebab `id:` values
# (parsed by parseRegistry into id↔name maps), the linter performs two
# distinct lookups against `_data_systems.yaml`:
#
#   1) Every entry in frontmatter `systems:` must be a known `id:` —
#      checked against registry.byID. A plan that left a display name in
#      `systems:` (a common migration slip) fails here.
#   2) Every EARS subject in body text (a display name like "Auth
#      Service") must resolve to an id via registry.byName; the resolved
#      id set must equal the declared `systems:` id set exactly.
#
# Partial registry entries (missing `id:` OR missing `name:`) are dropped
# silently by parseRegistry — the per-file lint surfaces them at the
# point a plan tries to reference the half-defined entry.

case_start "lint passes: id frontmatter + display-name EARS subject resolves cleanly"
PROJ_ID_HP="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_HP"
write_registry "$PROJ_ID_HP/${PLANS_DIR}" "Auth Service"
hp_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
write_full_plan "$PROJ_ID_HP/${PLANS_DIR}" "$hp_name" "valid" "auth-service" "Auth Service"
cd "$PROJ_ID_HP"
run_capture "" plans lint
assert_eq "exit 0"        "$RUN_RC" "0"
assert_contains "ok line" "$RUN_OUT" "$hp_name: ok"

case_start "lint flags frontmatter that uses a display name where an id belongs"
# A typical migration slip: author left `Auth Service` (the display name)
# in `systems:` instead of switching to the kebab id. Lint must surface
# it as "declared system not in registry".
PROJ_ID_BAD="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_BAD"
write_registry "$PROJ_ID_BAD/${PLANS_DIR}" "Auth Service"
bad_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_BAD/${PLANS_DIR}/$bad_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                    "$RUN_RC" "1"
assert_contains "id-not-in-registry"  "$RUN_OUT" "declared system \"Auth Service\" is not in"

case_start "lint flags EARS subject whose display name isn't in registry"
# Registry has only Auth Service. Frontmatter declares its id cleanly,
# but the body's EARS task names a system that has no registry entry —
# the new name→id resolution surfaces "EARS subject is not in <registry>".
PROJ_ID_ES="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_ES"
write_registry "$PROJ_ID_ES/${PLANS_DIR}" "Auth Service"
es_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_ES/${PLANS_DIR}/$es_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "unknown-subject"        "$RUN_OUT" "EARS subject \"Phantom Service\" is not in"

case_start "lint passes on multi-system plan with all subjects resolved cleanly"
# Two registered systems, both declared in frontmatter by id and both
# named in the body. The name→id translation collapses to the same id
# set on both sides; no findings should fire.
PROJ_ID_MS="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_MS"
write_registry "$PROJ_ID_MS/${PLANS_DIR}" "Auth Service,Billing Service"
ms_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_MS/${PLANS_DIR}/$ms_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 0"        "$RUN_RC" "0"
assert_contains "ok line" "$RUN_OUT" "$ms_name: ok"

case_start "lint flags partial registry entry (id only): plan can't reference it"
# parseRegistry drops entries with no `name:`. Referencing the dropped
# id from frontmatter therefore surfaces an "id not in registry" finding.
PROJ_ID_PI="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_PI"
cat > "$PROJ_ID_PI/${PLANS_DIR}/${PLANS_SYSTEMS_FILE}" <<EOF
systems:
  - id: auth-service
    name: Auth Service
    brief: handles auth
  - id: partial-thing
    brief: missing name field
EOF
pi_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_PI/${PLANS_DIR}/$pi_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "partial entry dropped"  "$RUN_OUT" "declared system \"partial-thing\" is not in"

case_start "lint flags partial registry entry (name only): EARS subject can't resolve"
# Mirror image of the previous case: an entry with `name:` but no `id:`
# is dropped, so body subject "Lone Name" has no id to resolve to.
PROJ_ID_PN="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_PN"
cat > "$PROJ_ID_PN/${PLANS_DIR}/${PLANS_SYSTEMS_FILE}" <<EOF
systems:
  - id: auth-service
    name: Auth Service
    brief: handles auth
  - name: Lone Name
    brief: missing id field
EOF
pn_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_PN/${PLANS_DIR}/$pn_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                        "$RUN_RC" "1"
assert_contains "name-only entry dropped" "$RUN_OUT" "EARS subject \"Lone Name\" is not in"

case_start "lint flags display-name-in-systems AND subject-id-not-resolved together"
# Author put a display name in `systems:` AND the body subject happens to
# match an existing registry name. The id-membership check fails on the
# frontmatter; the EARS check ALSO fires because subject→id resolves to
# "auth-service" which isn't in the declared set ["Auth Service"].
PROJ_ID_BOTH="$(fresh_project)"
seed_project_scaffold "$PROJ_ID_BOTH"
write_registry "$PROJ_ID_BOTH/${PLANS_DIR}" "Auth Service"
both_name="$(prefix "$DEFAULT_PREFIX_WIDTH" 1)-foo.md"
cat > "$PROJ_ID_BOTH/${PLANS_DIR}/$both_name" <<EOF
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
run_capture "" plans lint
assert_eq "exit 1"                              "$RUN_RC" "1"
assert_contains "frontmatter id rejected"       "$RUN_OUT" "declared system \"Auth Service\" is not in"
assert_contains "EARS subject not declared"     "$RUN_OUT" "EARS tasks name systems not in \`systems:\`"
assert_contains "frontmatter id orphaned"       "$RUN_OUT" "\`systems:\` declares systems not used in any EARS task"

# ---------- relation back-links: supersedes/superseded_by + extends/extended_by ----------
#
# `x-x plans lint` enforces, for each forward/back pair:
#   1) every slug in the array resolves to a sibling plan
#   2) a plan cannot reference itself in any of these arrays
#   3) the forward link and back link are symmetric across plans
#
# These cases pin every observable corner of that contract. The
# write_relation_plan helper composes a lint-passing baseline (title,
# status, systems, EARS body, created) and splices in whatever relation
# line(s) the case wants right before `created:`.

# write_relation_plan <dir> <name> <status> <relation-lines>
# <relation-lines> may be empty or contain one or more newline-separated
# frontmatter keys (e.g. `supersedes: [00002-bar]`).
write_relation_plan() {
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
write_registry "$PROJ_REL_SH/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_SH/${PLANS_DIR}" "${rel_b}.md" "valid"      "supersedes: [${rel_a}]"
write_relation_plan "$PROJ_REL_SH/${PLANS_DIR}" "${rel_a}.md" "superseded" "superseded_by: [${rel_b}]"
cd "$PROJ_REL_SH"
run_capture "" plans lint
assert_eq "lint exit 0 on symmetric supersedes pair" "$RUN_RC" "0"

case_start "lint passes: extends/extended_by symmetric pair"
PROJ_REL_EH="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_EH"
write_registry "$PROJ_REL_EH/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_EH/${PLANS_DIR}" "${rel_b}.md" "valid" "extends: [${rel_a}]"
write_relation_plan "$PROJ_REL_EH/${PLANS_DIR}" "${rel_a}.md" "valid" "extended_by: [${rel_b}]"
cd "$PROJ_REL_EH"
run_capture "" plans lint
assert_eq "lint exit 0 on symmetric extends pair" "$RUN_RC" "0"

case_start "lint passes: both pairs present and symmetric on the same predecessor"
# A is superseded by B AND extended by C (a degenerate corner case — once
# something is superseded its 'extended_by' is academic — but lint
# doesn't forbid the combination, and the user might have it during a
# multi-step migration).
PROJ_REL_MIX="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_MIX"
write_registry "$PROJ_REL_MIX/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_MIX/${PLANS_DIR}" "${rel_b}.md" "valid"      "supersedes: [${rel_a}]"
write_relation_plan "$PROJ_REL_MIX/${PLANS_DIR}" "${rel_c}.md" "valid"      "extends: [${rel_a}]"
write_relation_plan "$PROJ_REL_MIX/${PLANS_DIR}" "${rel_a}.md" "superseded" "$(printf 'superseded_by: [%s]\nextended_by: [%s]' "$rel_b" "$rel_c")"
cd "$PROJ_REL_MIX"
run_capture "" plans lint
assert_eq "lint exit 0 with mixed-relation predecessor" "$RUN_RC" "0"

case_start "lint flags dangling supersedes slug"
PROJ_REL_DSF="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_DSF"
write_registry "$PROJ_REL_DSF/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_DSF/${PLANS_DIR}" "${rel_a}.md" "valid" "supersedes: [${dangling}]"
cd "$PROJ_REL_DSF"
run_capture "" plans lint
assert_eq "exit 1"                          "$RUN_RC" "1"
assert_contains "dangling supersedes"       "$RUN_OUT" "supersedes \"${dangling}\""

case_start "lint flags dangling superseded_by slug"
PROJ_REL_DSB="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_DSB"
write_registry "$PROJ_REL_DSB/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_DSB/${PLANS_DIR}" "${rel_a}.md" "superseded" "superseded_by: [${dangling}]"
cd "$PROJ_REL_DSB"
run_capture "" plans lint
assert_eq "exit 1"                              "$RUN_RC" "1"
assert_contains "dangling superseded_by"        "$RUN_OUT" "superseded_by \"${dangling}\""

case_start "lint flags dangling extends slug"
PROJ_REL_DEF="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_DEF"
write_registry "$PROJ_REL_DEF/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_DEF/${PLANS_DIR}" "${rel_a}.md" "valid" "extends: [${dangling}]"
cd "$PROJ_REL_DEF"
run_capture "" plans lint
assert_eq "exit 1"                        "$RUN_RC" "1"
assert_contains "dangling extends"        "$RUN_OUT" "extends \"${dangling}\""

case_start "lint flags dangling extended_by slug"
PROJ_REL_DEB="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_DEB"
write_registry "$PROJ_REL_DEB/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_DEB/${PLANS_DIR}" "${rel_a}.md" "valid" "extended_by: [${dangling}]"
cd "$PROJ_REL_DEB"
run_capture "" plans lint
assert_eq "exit 1"                            "$RUN_RC" "1"
assert_contains "dangling extended_by"        "$RUN_OUT" "extended_by \"${dangling}\""

case_start "lint flags self-supersedes"
PROJ_REL_SS="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_SS"
write_registry "$PROJ_REL_SS/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_SS/${PLANS_DIR}" "${rel_a}.md" "valid" "supersedes: [${rel_a}]"
cd "$PROJ_REL_SS"
run_capture "" plans lint
assert_eq "exit 1"                       "$RUN_RC" "1"
assert_contains "self-supersedes"        "$RUN_OUT" "supersedes cannot reference the plan itself"

case_start "lint flags self-extends"
PROJ_REL_SE="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_SE"
write_registry "$PROJ_REL_SE/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_SE/${PLANS_DIR}" "${rel_a}.md" "valid" "extends: [${rel_a}]"
cd "$PROJ_REL_SE"
run_capture "" plans lint
assert_eq "exit 1"                    "$RUN_RC" "1"
assert_contains "self-extends"        "$RUN_OUT" "extends cannot reference the plan itself"

case_start "lint flags asymmetric supersedes (forward present, back missing)"
PROJ_REL_AS1="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_AS1"
write_registry "$PROJ_REL_AS1/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_AS1/${PLANS_DIR}" "${rel_b}.md" "valid" "supersedes: [${rel_a}]"
write_relation_plan "$PROJ_REL_AS1/${PLANS_DIR}" "${rel_a}.md" "superseded" ""
cd "$PROJ_REL_AS1"
run_capture "" plans lint
assert_eq "exit 1"                                     "$RUN_RC" "1"
assert_contains "missing superseded_by back-link"      "$RUN_OUT" "does not list this plan in its \`superseded_by:\` array"

case_start "lint flags asymmetric supersedes (back present, forward missing)"
PROJ_REL_AS2="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_AS2"
write_registry "$PROJ_REL_AS2/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_AS2/${PLANS_DIR}" "${rel_a}.md" "superseded" "superseded_by: [${rel_b}]"
write_relation_plan "$PROJ_REL_AS2/${PLANS_DIR}" "${rel_b}.md" "valid" ""
cd "$PROJ_REL_AS2"
run_capture "" plans lint
assert_eq "exit 1"                                "$RUN_RC" "1"
assert_contains "missing supersedes back-link"    "$RUN_OUT" "does not list this plan in its \`supersedes:\` array"

case_start "lint flags asymmetric extends (forward present, back missing)"
PROJ_REL_AE1="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_AE1"
write_registry "$PROJ_REL_AE1/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_AE1/${PLANS_DIR}" "${rel_b}.md" "valid" "extends: [${rel_a}]"
write_relation_plan "$PROJ_REL_AE1/${PLANS_DIR}" "${rel_a}.md" "valid" ""
cd "$PROJ_REL_AE1"
run_capture "" plans lint
assert_eq "exit 1"                                  "$RUN_RC" "1"
assert_contains "missing extended_by back-link"     "$RUN_OUT" "does not list this plan in its \`extended_by:\` array"

case_start "lint flags asymmetric extends (back present, forward missing)"
PROJ_REL_AE2="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_AE2"
write_registry "$PROJ_REL_AE2/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_AE2/${PLANS_DIR}" "${rel_a}.md" "valid" "extended_by: [${rel_b}]"
write_relation_plan "$PROJ_REL_AE2/${PLANS_DIR}" "${rel_b}.md" "valid" ""
cd "$PROJ_REL_AE2"
run_capture "" plans lint
assert_eq "exit 1"                              "$RUN_RC" "1"
assert_contains "missing extends back-link"     "$RUN_OUT" "does not list this plan in its \`extends:\` array"

case_start "lint passes: multi-element extends with all back-links present"
PROJ_REL_MA="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_MA"
write_registry "$PROJ_REL_MA/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_MA/${PLANS_DIR}" "${rel_c}.md" "valid" "extends: [${rel_a}, ${rel_b}]"
write_relation_plan "$PROJ_REL_MA/${PLANS_DIR}" "${rel_a}.md" "valid" "extended_by: [${rel_c}]"
write_relation_plan "$PROJ_REL_MA/${PLANS_DIR}" "${rel_b}.md" "valid" "extended_by: [${rel_c}]"
cd "$PROJ_REL_MA"
run_capture "" plans lint
assert_eq "lint exit 0 multi-element symmetric" "$RUN_RC" "0"

case_start "lint flags only the asymmetric pair in a multi-element extends"
# C extends [A, B]. A has the back link; B does not. Lint must catch the
# B half without false-flagging A.
PROJ_REL_PA="$(fresh_project)"
seed_project_scaffold "$PROJ_REL_PA"
write_registry "$PROJ_REL_PA/${PLANS_DIR}" "Auth Service"
write_relation_plan "$PROJ_REL_PA/${PLANS_DIR}" "${rel_c}.md" "valid" "extends: [${rel_a}, ${rel_b}]"
write_relation_plan "$PROJ_REL_PA/${PLANS_DIR}" "${rel_a}.md" "valid" "extended_by: [${rel_c}]"
write_relation_plan "$PROJ_REL_PA/${PLANS_DIR}" "${rel_b}.md" "valid" ""
cd "$PROJ_REL_PA"
run_capture "" plans lint
assert_eq "exit 1"                                  "$RUN_RC" "1"
assert_contains "asymmetric half flagged"           "$RUN_OUT" "extends \"${rel_b}\" but \"${rel_b}\" does not list this plan in its \`extended_by:\` array"
assert_not_contains "symmetric half not flagged"    "$RUN_OUT" "extends \"${rel_a}\" but \"${rel_a}\" does not list"

# ---------- plan slugify ----------

case_start "x-x plans slugify basic title"
run_capture "" plans slugify "Hello World"
assert_eq "exit 0"            "$RUN_RC" "0"
assert_eq "slug printed"      "$RUN_OUT" "hello-world"

case_start "x-x plans slugify collapses runs of non-alnum"
run_capture "" plans slugify "  Foo // Bar  "
assert_eq "exit 0"          "$RUN_RC" "0"
assert_eq "collapsed slug"  "$RUN_OUT" "foo-bar"

case_start "x-x plans slugify lowercases ASCII"
run_capture "" plans slugify "ALL CAPS"
assert_eq "exit 0"        "$RUN_RC" "0"
assert_eq "lowered slug"  "$RUN_OUT" "all-caps"

case_start "x-x plans slugify rejects missing arg"
run_capture "" plans slugify
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "exactly one positional"

case_start "x-x plans slugify rejects multiple args"
run_capture "" plans slugify "foo" "bar"
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "exactly one positional"

case_start "x-x plans slugify rejects unsluggable title"
run_capture "" plans slugify "!!!"
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "no slug-able characters"

case_start "x-x plans slugify accepts pure numerics"
run_capture "" plans slugify "123"
assert_eq "exit 0"           "$RUN_RC" "0"
assert_eq "numeric slug"     "$RUN_OUT" "123"

case_start "x-x plans slugify accepts leading-dash titles after --"
# Bare `-foo` would be caught by flag.Parse as "bad flag syntax"; the
# standard `--` end-of-flags separator delivers it as a positional.
run_capture "" plans slugify -- "-foo bar"
assert_eq "exit 0"           "$RUN_RC" "0"
assert_eq "leading-dash slug" "$RUN_OUT" "foo-bar"

case_start "x-x plans slugify drops non-ASCII; wholly-non-ASCII is unsluggable"
run_capture "" plans slugify "Plan プラン"
assert_eq "exit 0"           "$RUN_RC" "0"
assert_eq "mixed slug"       "$RUN_OUT" "plan"
run_capture "" plans slugify "プラン"
assert_eq "exit 2"           "$RUN_RC" "2"
assert_contains "diagnostic" "$RUN_ERR" "no slug-able characters"

case_start "x-x plans slugify collapses tabs and newlines"
# printf is run inside the same shell that invokes the binary, so escape
# sequences expand before the arg leaves the shell.
run_capture "" plans slugify "$(printf 'Foo\tBar\nBaz')"
assert_eq "exit 0"           "$RUN_RC" "0"
assert_eq "ws-collapsed slug" "$RUN_OUT" "foo-bar-baz"

case_start "x-x plans slugify works outside an x-x project"
# Pure transform; no project gate. Run from a directory with no .x-plans/
# to pin that contract.
PROJ_SG="$(fresh_project)"
cd "$PROJ_SG"
run_capture "" plans slugify "Outside Project"
assert_eq "exit 0"        "$RUN_RC" "0"
assert_eq "slug printed"  "$RUN_OUT" "outside-project"

# ---------- per-subcommand --help / -h ----------

case_start "x-x init -h prints init usage"
run_capture "" init -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "init usage header"  "$combined" "Usage: x-x init"
assert_contains "agents flag listed" "$combined" "--agents"
assert_contains "scope flag listed"  "$combined" "--scope"

case_start "x-x skills remove -h prints remove usage"
run_capture "" skills remove -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "remove usage header" "$combined" "Usage: x-x skills remove"

case_start "x-x plans next-prefix -h prints next-prefix usage"
run_capture "" plans next-prefix -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "next-prefix usage header" "$combined" "Usage: x-x plans next-prefix"

case_start "x-x plans lint -h prints lint usage"
run_capture "" plans lint -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "lint usage header" "$combined" "Usage: x-x plans lint"

case_start "x-x plans slugify -h prints slugify usage"
run_capture "" plans slugify -h
combined="${RUN_OUT}${RUN_ERR}"
assert_contains "slugify usage header" "$combined" "Usage: x-x plans slugify"

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
