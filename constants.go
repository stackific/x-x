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

	// plansDir is the per-project directory that holds plan files and the
	// plan-tooling scaffold. Lives at <cwd>/<plansDir>.
	plansDir = ".x-plans"

	// plansConfigLockFile pins the plan-tooling defaults inside plansDir.
	// Treated as a lock file (Cargo.lock, package-lock.json semantics):
	// init writes it once and never refreshes it on subsequent runs.
	plansConfigLockFile = "_config.lock"

	// plansSystemsFile is the system registry inside plansDir — populated
	// by the user as they add EARS systems. init seeds it as a zero-byte
	// placeholder if absent.
	plansSystemsFile = "_data_systems.yaml"

	// planFileExt is the on-disk extension every plan file carries. Pulled
	// out as a constant so plan.go's filename-format regexes, glob, and
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
//	key           — short, stable CLI identifier (e.g. "claude", "codex").
//	                Surfaced through `--agents claude,codex` and the
//	                interactive multi-select. Must be lowercase, no spaces.
//	name          — human-readable label printed in the progress log and in
//	                the interactive agent picker.
//	skillsRel     — destination for agents/skills/*; relative to scope root.
//	                Used for BOTH scopes by default. For agents whose CLI
//	                reads from different paths at project vs user scope
//	                (e.g. GitHub Copilot CLI: `.agents/skills` at project,
//	                `~/.copilot/skills` at user), populate userSkillsRel too.
//	userSkillsRel — optional override for user scope ($HOME-relative). When
//	                empty the install/remove code falls back to skillsRel
//	                in both scopes. When set, project scope still uses
//	                skillsRel and user scope uses this field.
//	configSrc     — subdir under ~/.x-x/agents/ holding agent-specific files
//	                (e.g. "claude" for agents/claude/settings.json). Empty
//	                means this agent has no per-agent config to install.
//	configRel     — destination for the configSrc files, relative to scope root
//	                (e.g. ".claude" so that agents/claude/settings.json lands
//	                at <root>/.claude/settings.json).
type agentTarget struct {
	key           string
	name          string
	skillsRel     string
	userSkillsRel string
	configSrc     string
	configRel     string
}

// skillsRelFor returns the scope-correct skill install path for one agent.
// project scope always uses skillsRel; user scope prefers userSkillsRel when
// set, falling back to skillsRel otherwise. Centralized so install AND
// remove paths can't diverge. Pointer receiver because agentTarget hit
// gocritic's hugeParam threshold (96 bytes) after the userSkillsRel field
// was added.
func (t *agentTarget) skillsRelFor(scope initScope) string {
	if scope == scopeUser && t.userSkillsRel != "" {
		return t.userSkillsRel
	}
	return t.skillsRel
}

// agentTargets is the registry consulted by `x-x init` and `x-x skills
// remove`. Add a new agent by appending a row; do NOT add per-agent
// special cases in the install/remove code. To add an agent that ships
// skills only (no per-agent config), leave configSrc and configRel empty.
//
// `key` is the value users type in `--agents <key>[,<key>...]` and in
// the interactive multi-select picker — keep it short, lowercase, and
// unique across the registry.
var agentTargets = []agentTarget{
	{"claude", "Claude Code", ".claude/skills", "", "claude", ".claude"},
	// Codex CLI scans .agents/skills/ at every level (cwd → repo root → $HOME),
	// per the cross-agent SKILL.md open standard. The legacy ~/.codex/skills
	// is also recognized at user scope but not at project scope, so .agents
	// is the one path that works in both modes. Per-agent config (hooks.json,
	// config.toml, etc.) still lives under .codex/ — see Codex docs:
	// https://developers.openai.com/codex/hooks for the lookup order.
	{"codex", "Codex CLI", ".agents/skills", "", "codex", ".codex"},
	// OpenCode resolves slash commands from `.opencode/{command,commands}/**/*.md`
	// at project scope and `~/.config/opencode/commands/` at user scope.
	// The lookup keys off the file's frontmatter `name:` (the path-derived
	// fallback is used only when frontmatter omits `name:`), so an x-x
	// install at `.opencode/commands/x-plan/SKILL.md` with `name: x-plan`
	// registers a command callable as both `/x-plan` in the TUI and
	// `opencode run --command x-plan ...` from the CLI (sst/opencode
	// PR #2348). The bundled tree shape (`<command>/SKILL.md` rather than
	// flat `<command>.md`) matches Claude/Codex for parity across agents.
	// No per-agent config is bundled for OpenCode yet (auth + provider
	// routing live outside the install scope, in `~/.local/share/opencode/`).
	{"opencode", "OpenCode", ".opencode/commands", "", "", ""},
	// GitHub Copilot CLI reads skills from `.agents/skills/`, `.claude/skills/`,
	// or `.github/skills/` at project scope, and `~/.copilot/skills/` or
	// `~/.agents/skills/` at user scope (per Copilot CLI's May 2026 docs at
	// docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills).
	// We use `.agents/skills` at BOTH scopes — the cross-agent open spec
	// path. Reasons:
	//   1. agents/skills/x-plan/SKILL.md and agents/skills/x-x/SKILL.md
	//      define `<skills_root>` as exactly `.claude/skills/` (Claude) or
	//      `.agents/skills/` (other agents). The agent's path-resolution
	//      logic globs that exact list — `.copilot/skills` is not in it.
	//   2. `~/.agents/skills` is on Copilot CLI's official user-scope list
	//      alongside `~/.copilot/skills`. Both work for skill discovery.
	//   3. Reusing `.agents/skills` co-locates with Codex (install is
	//      idempotent), keeping the registry uniform across "other agents".
	// Skills-only for now — no settings.json / hooks file shipped yet;
	// that's a follow-up once the manual eval workflow tells us which
	// Copilot CLI lifecycle hooks make sense to register.
	{"copilot", "GitHub Copilot CLI", ".agents/skills", "", "", ""},
	// Kilo Code CLI is a fork of anomalyco/opencode and reads skills from
	// `.kilo/skills/`, `.agents/skills/` ("Open agent standard, loaded by
	// default"), and `.claude/skills/` ("Claude Code compatibility, loaded
	// when Claude Code Compatibility is enabled") at project scope; user
	// scope is documented as `~/.kilo/skills/` (kilo.ai/docs/customize/skills,
	// May 2026). We use `.agents/skills` at BOTH scopes — same reasoning as
	// the Copilot row above:
	//   1. agents/skills/x-plan/SKILL.md and agents/skills/x-x/SKILL.md
	//      define `<skills_root>` as exactly `.claude/skills/` (Claude) or
	//      `.agents/skills/` (other agents). The agent's path-resolution
	//      logic globs that exact list — `.kilo/skills` is not in it.
	//   2. `.agents/skills/` is Kilo's documented "open agent standard"
	//      compat path, loaded by default at project scope. Empirical
	//      evidence from the eval (manual-kilocode-judge*.yml) confirms
	//      the user-scope `~/.agents/skills/` lookup works the same way
	//      Copilot's does — both binaries fall back through the
	//      cross-agent discovery list at $HOME.
	//   3. Reusing `.agents/skills` co-locates with Codex / Copilot
	//      (install is idempotent), keeping the registry uniform across
	//      "other agents".
	// Skills-only — no settings.json / hooks file shipped yet; that's a
	// follow-up once the eval workflow tells us which Kilo lifecycle
	// hooks make sense to register.
	{"kilo", "Kilo Code", ".agents/skills", "", "", ""},
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
// `x-x skills remove` consults this constant to scope its un-merge:
// only entries underneath this property are candidates for subtraction,
// and even then only when they deep-equal a record in the currently
// bundled file. Renaming the key in a future config schema = update
// this constant + the matching property in `agents/<agent>/*.json`.
const configHooksKey = "hooks"

// Plan-tooling defaults pinned into .x-plans/_config.lock by
// writePlansScaffold during `x-x init`. The `x-x plans` subcommands read
// these values from the lock file at runtime; the binary is the standard
// source for new projects while existing projects keep whatever they
// pinned on their first `x-x init`. Bump these numbers to change behavior
// going forward without disturbing prior installs.
const (
	// defaultPrefixWidth is the zero-padded width of plan-file numeric
	// prefixes (e.g. width 4 → "0001-foo.md"). Bump to widen prefixes.
	defaultPrefixWidth = 4

	// defaultMaxPlanLines is the line-count ceiling `x-x plans lint`
	// enforces on a single plan file (frontmatter + body, inclusive).
	defaultMaxPlanLines = 30

	// plansListOverflowThreshold is the row count above which
	// `x-x plans list` activates the optional `--overflow-keywords` narrow.
	// At or below this count every matching plan is returned regardless
	// of whether keywords were supplied. Tuned for LLM consumption — a
	// list this short fits comfortably in context without narrowing.
	// Bump this number to relax the trigger, or pass `--overflow-keywords`
	// from a caller that wants the optional narrowing to engage.
	plansListOverflowThreshold = 20

	// defaultReviewPer controls whether the planner pauses for review
	// after every "task" or after every "plan" (other valid value).
	defaultReviewPer = reviewPerTask

	// reviewPerTask / reviewPerPlan are the two valid values for
	// the review_per key. Named constants so the init prompt, flag
	// validator, and downstream consumers all reference the same string —
	// typo-resistant by construction. Add a new value here, then expose it
	// in the picker and the --review-per validator.
	reviewPerTask = "task"
	reviewPerPlan = "plan"
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
	skillXPlanDir = "x-plan"
	skillXXDir    = "x-x"
)

// skillManifestFile is the manifest filename every bundled skill ships
// under its directory (cross-agent SKILL.md open standard — Claude Code,
// Codex CLI, and Gemini all look for this exact name). Pulled into a
// constant so tests that round-trip files out of the embed don't violate
// the "no inline path literals in Go source" rule.
const skillManifestFile = "SKILL.md"

// ownedSkills is the standard, exhaustive list of skill directory names
// the binary ships and is allowed to delete. `x-x skills remove` uses this
// as a strict allowlist — a folder named anything else under .claude/skills
// or .agents/skills is the user's, never ours, and is always left alone.
//
// Keep this in sync with the directories under agents/skills/ in the repo.
// Adding a new bundled skill = adding a `skill*Dir` constant above and
// appending it here. The embed.FS-driven install pulls in whatever is on
// disk; this list is the matching allowlist for removal.
var ownedSkills = []string{
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
//nolint:unused // documentation registry; will be surfaced in `x-x skills remove` UX.
var ownedFiles = []string{
	// Plan-tooling scaffold seeded by writePlansScaffold (project scope only).
	plansDir + "/" + plansSystemsFile,
	plansDir + "/" + plansConfigLockFile,
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

	// installShURL / installPS1URL are the standard install-script URLs
	// surfaced to the user in the "update available" nudge. The README
	// and docs/public/getting-started.md should match these strings.
	installShURL  = "https://stackific.com/x-x/INSTALL.sh"
	installPS1URL = "https://stackific.com/x-x/INSTALL.ps1"
)
