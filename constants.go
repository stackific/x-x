// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

// Package main is the entire x-x CLI. Everything lives in a single package
// because the binary is small enough that splitting into internal/* would
// add ceremony without buying abstraction. Per-feature files (main.go,
// init.go, agents.go, etc.) group functions by responsibility, and this
// constants.go is the one place package-level configuration lives so the
// rest of the codebase reads from a single source of truth.
package main

// time is imported here for the update-check interval and HTTP timeout
// constants further down. No other package-level dependency is needed.
import "time"

// Version is the human-readable release tag, e.g. "v0.1.0". It is a `var`
// (not `const`) so the release workflow can inject the real value at link
// time via `-ldflags "-X main.Version=v..."`. Local builds (`go build` or
// `go run .`) keep the "dev" sentinel — maybeNotifyUpdate explicitly skips
// the GitHub round-trip when it sees that string, so contributors hacking
// on the binary don't get spammed with "new version available" nudges.
var Version = "dev"

// productTagline is the one-line marketing-ish blurb printed under the
// version banner by printAbout. It is kept as a const (rather than a
// string literal in printAbout) so it can be reused if the project ever
// adds an `--about` machine-readable form or a JSON status command.
// Note: the trailing "\n" is intentional — callers use fmt.Print (not
// Println) so the newline lives on the constant, not at the call site.
const productTagline = "An evidence-based, spec-driven agent skillset with enterprise accuracy at startup speed.\n"

// On-disk path components. Every path literal in the codebase MUST be
// composed from these constants — no inline string fragments like ".x-x"
// or "_config.lock" inside Go source. AGENTS.md codifies this as a hard
// rule; new path elements live here first, then get referenced elsewhere.
const (
	// xxHomeDir is the per-user state directory under $HOME. Holds the
	// materialized embed (xxHomeDir/agentsEmbedRoot/) and the update-check
	// config (xxHomeDir/xxConfigFile).
	xxHomeDir = ".x-x"

	// xxConfigFile is the JSON file inside xxHomeDir that records the
	// installed version + last-update-check epoch. Written by the
	// installer scripts and rewritten by maybeNotifyUpdate.
	xxConfigFile = ".config.json"

	// agentsEmbedRoot is the directory name inside the embeddedAgents FS
	// AND the on-disk subdirectory name under xxHomeDir. The dual role is
	// intentional — one constant keeps embed source and disk destination
	// aligned. Must match the path in the `//go:embed all:agents`
	// directive in agents.go.
	agentsEmbedRoot = "agents"

	// planDir is the per-project directory that holds plan files and the
	// plan-tooling scaffold. Lives at <cwd>/<planDir>.
	planDir = ".x-plan"

	// planConfigLockFile pins the plan-tooling defaults inside planDir.
	// Treated as a lock file (Cargo.lock, package-lock.json semantics):
	// init writes it once and never refreshes it on subsequent runs.
	planConfigLockFile = "_config.lock"

	// planSystemsFile is the system registry inside planDir — populated
	// by the user as they add EARS systems. init seeds it as a zero-byte
	// placeholder if absent.
	planSystemsFile = "_data_systems.yaml"

	// planFileExt is the on-disk extension every plan file carries. Pulled
	// out as a constant so plan.go's filename-shape regexes, glob, and
	// suffix-trimming all reference the same value — adding a future
	// alternative extension (e.g. ".plan.md") is then a one-line change.
	planFileExt = ".md"
)

// agentTarget describes one downstream destination managed by `x-x init`.
// The CLI walks agentTargets and installs the bundled skill library into
// each row's skillsRel directory, plus optional per-agent config files
// from each row's configSrc subtree. Adding a future agent = appending a
// row — no code-branch edits required.
//
// Field roles:
//
//	key       — short, stable CLI identifier (e.g. "claude", "codex").
//	            Surfaced through `--agents claude,codex` and the
//	            interactive multi-select. Must be lowercase, no spaces.
//	name      — human-readable label printed in the progress log and in
//	            the interactive agent picker.
//	skillsRel — destination for agents/skills/*; relative to scope root
//	            ($HOME for user scope, cwd for project scope). The string
//	            is identical for both scopes today, but the field is named
//	            "Rel" to make that explicit.
//	configSrc — subdir under ~/.x-x/agents/ holding agent-specific files
//	            (e.g. "claude" for agents/claude/settings.json). Empty
//	            means this agent has no per-agent config to install.
//	configRel — destination for the configSrc files, relative to scope root
//	            (e.g. ".claude" so that agents/claude/settings.json lands
//	            at <root>/.claude/settings.json).
type agentTarget struct {
	key       string
	name      string
	skillsRel string
	configSrc string
	configRel string
}

// agentTargets is the registry consulted by `x-x init` and `x-x skill
// remove`. Add a new agent by appending a row; do NOT add per-agent
// special cases in the install/remove code. To add an agent that ships
// skills only (no per-agent config), leave configSrc and configRel empty.
//
// `key` is the value users type in `--agents <key>[,<key>...]` and in
// the interactive multi-select picker — keep it short, lowercase, and
// unique across the registry.
var agentTargets = []agentTarget{
	{"claude", "Claude Code", ".claude/skills", "claude", ".claude"},
	// Codex CLI scans .agents/skills/ at every level (cwd → repo root → $HOME),
	// per the cross-agent SKILL.md open standard. The legacy ~/.codex/skills
	// is also recognized at user scope but not at project scope, so .agents
	// is the one path that works in both modes. Per-agent config (hooks.json,
	// config.toml, etc.) still lives under .codex/ — see Codex docs:
	// https://developers.openai.com/codex/hooks for the lookup order.
	{"codex", "Codex CLI", ".agents/skills", "codex", ".codex"},
}

// skillsSubdir is the directory inside ~/.x-x/agents/ that holds the
// cross-agent skill library — one subdirectory per skill. Pulled out as
// a constant because init.go and the on-disk write path both depend on it.
const skillsSubdir = "skills"

// configJSONExt is the extension `installAgentConfig` keys on to decide
// between two re-run policies for a destination that already exists:
//
//	`.json` files → deep-merge bundled into existing (user scalars win,
//	  bundled keys added when missing, array entries unioned).
//	everything else → skip with a "skipping" log so user edits survive.
//
// Today every bundled config file (Claude `settings.json`, Codex
// `hooks.json`) is JSON, so the merge path is the common case. The
// constant lives here so adding a future TOML/YAML merger only needs
// a new sibling and a tiny installAgentConfig branch.
const configJSONExt = ".json"

// configHooksKey is the top-level JSON property inside every bundled
// per-agent config file (`agents/claude/settings.json`,
// `agents/codex/hooks.json`) under which x-x's shipped hook records
// live. The files themselves are user-owned end-to-end; what x-x owns
// are individual leaf records inside the arrays nested under this key.
//
// `x-x skill remove` consults this constant to scope its un-merge:
// only entries underneath this property are candidates for subtraction,
// and even then only when they deep-equal a record in the currently
// bundled file. Renaming the key in a future config schema = update
// this constant + the matching property in `agents/<agent>/*.json`.
const configHooksKey = "hooks"

// Plan-tooling defaults pinned into .x-plan/_config.lock by
// writePlanScaffold during `x-x init`. The `x-x plan` subcommands read
// these values from the lock file at runtime; the binary is the canonical
// source for new projects while existing projects keep whatever they
// pinned on their first `x-x init`. Bump these numbers to change behavior
// going forward without disturbing prior installs.
const (
	// defaultPrefixWidth is the zero-padded width of plan-file numeric
	// prefixes (e.g. width 4 → "0001-foo.md"). Bump to widen prefixes.
	defaultPrefixWidth = 4

	// defaultMaxPlanLines is the line-count ceiling `x-x plan lint`
	// enforces on a single plan file (frontmatter + body, inclusive).
	defaultMaxPlanLines = 30

	// planListOverflowThreshold is the row count above which
	// `x-x plan list` activates the optional `--overflow-keywords` narrow.
	// At or below this count every matching plan is returned regardless
	// of whether keywords were supplied. Tuned for LLM consumption — a
	// list this short fits comfortably in context without narrowing.
	// Bump this number to relax the trigger, or pass `--overflow-keywords`
	// from a caller that wants the optional narrowing to engage.
	planListOverflowThreshold = 20

	// defaultPlanReviewPer controls whether the planner pauses for review
	// after every "task" or after every "plan" (other valid value).
	defaultPlanReviewPer = planReviewPerTask

	// planReviewPerTask / planReviewPerPlan are the two valid values for
	// the plan_review_per key. Named constants so the init prompt, flag
	// validator, and downstream consumers all reference the same string —
	// typo-resistant by construction. Add a new value here, then expose it
	// in the picker and the --plan-review-per validator.
	planReviewPerTask = "task"
	planReviewPerPlan = "plan"
)

// skipFromEmbed lists embed-relative paths (forward-slash, relative to
// agentsEmbedRoot) that writeBundledAgents must NOT copy onto the user's
// machine. The directive `//go:embed all:agents` pulls in everything under
// agents/, but a handful of those files are repo-only metadata (READMEs
// for contributors browsing GitHub) that have no business in ~/.x-x/agents.
var skipFromEmbed = map[string]bool{
	"README.md": true,
}

// Bundled skill directory names. Every place in the Go code that needs to
// refer to a shipped skill by name must use one of these constants —
// renaming a skill is then a one-line edit here, plus the matching rename
// of the directory under agents/skills/ and any references inside the
// embedded markdown/json content. Non-Go consumers (scripts/e2e_test.sh,
// docs/public/reference.md) still hold literal strings; keep them in sync.
const (
	skillSharedDir = "_x-x_shared"
	skillXPlanDir  = "x-plan"
	skillXXDir     = "x-x"
)

// skillManifestFile is the manifest filename every bundled skill ships
// under its directory (cross-agent SKILL.md open standard — Claude Code,
// Codex CLI, and Gemini all look for this exact name). Pulled into a
// constant so tests that round-trip files out of the embed don't violate
// the "no inline path literals in Go source" rule.
const skillManifestFile = "SKILL.md"

// Filenames shipped under agents/skills/_x-x_shared/. The Go code
// embeds the whole directory wholesale and never opens these by name,
// but the e2e harness asserts on their post-install presence — so they
// must live in constants.go for the e2e shell mirror to be lawful.
// Renaming a shared file = edit here, edit the shell mirror, ship.
const (
	sharedDocPlanFirst = "_plan_first.md"
	sharedDocSystems   = "_systems.md"
	sharedDocEars      = "_ears.md"
)

// ownedSkills is the canonical, exhaustive list of skill directory names
// the binary ships and is allowed to delete. `x-x skill remove` uses this
// as a strict allowlist — a folder named anything else under .claude/skills
// or .agents/skills is the user's, never ours, and is always left alone.
//
// Keep this in sync with the directories under agents/skills/ in the repo.
// Adding a new bundled skill = adding a `skill*Dir` constant above and
// appending it here. The embed.FS-driven install pulls in whatever is on
// disk; this list is the matching allowlist for removal.
var ownedSkills = []string{
	skillSharedDir,
	skillXPlanDir,
	skillXXDir,
}

// ownedFiles is the exhaustive list of files (relative to the install scope
// root) that `x-x init` may have written. None of them carry a marker, and
// each `init` run leaves them alone if they already exist — so removal must
// be conservative (today: not automated). Recorded here so the inventory
// of "what x-x touches on disk" lives in one place, even though no code
// path currently iterates it (hence the nolint below).
//
//nolint:unused // documentation registry; will be surfaced in `x-x skill remove` UX.
var ownedFiles = []string{
	// Plan-tooling scaffold seeded by writePlanScaffold (project scope only).
	planDir + "/" + planSystemsFile,
	planDir + "/" + planConfigLockFile,
	// Per-agent config files copied from agents/<agent>/ by installAgentConfig.
	// Empty-target-only writes: an existing file is preserved.
	agentTargets[0].configRel + "/settings.json",
}

// Update-check settings — read by maybeNotifyUpdate / fetchLatestVersion.
// All values are package constants so the behavior can be reasoned about
// without inspecting individual call sites.
const (
	// updateCheckInterval bounds how often the CLI is willing to probe
	// GitHub for a new release. 24 hours is gentle enough to never hit
	// the 60-req/hour unauthenticated API limit even on a busy laptop.
	updateCheckInterval = 24 * time.Hour

	// updateHTTPTimeout is the wall-clock cap on the latest-release lookup.
	// Kept short — the check is opportunistic and must never delay the
	// user's main command on a slow network.
	updateHTTPTimeout = 3 * time.Second

	// releasesAPIURL is the unauthenticated endpoint that returns the
	// most recent release's metadata. Only the `tag_name` field is read.
	releasesAPIURL = "https://api.github.com/repos/stackific/x-x/releases/latest"

	// installShURL / installPS1URL are the canonical install-script URLs
	// surfaced to the user in the "update available" nudge. The README
	// and docs/public/getting-started.md should match these strings.
	installShURL  = "https://stackific.com/x-x/INSTALL.sh"
	installPS1URL = "https://stackific.com/x-x/INSTALL.ps1"
)
