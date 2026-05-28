// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

// Package main is the entire stax CLI. Everything lives in a single package
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
// composed from these constants — no inline string fragments like ".stax"
// or "_config.lock" inside Go source. AGENTS.md codifies this as a hard
// rule; new path elements live here first, then get referenced elsewhere.
const (
	// staxDir is the directory name used at BOTH scopes:
	//   - User scope: $HOME/<staxDir>/ holds the materialized embed
	//     (<staxDir>/agentsEmbedRoot/) and the update-check config
	//     (<staxDir>/staxConfigFile).
	//   - Project scope: <cwd>/<staxDir>/ holds the plan-tooling scaffold
	//     (staxLockFile, staxSystemsFile, *.md plan files).
	// The two scopes share the directory NAME but never the content — the
	// user-scope tree is binary-owned, the project-scope tree is user-owned.
	staxDir = ".stax"

	// staxConfigFile is the JSON file inside the user-scope staxDir that
	// records the installed version + last-update-check epoch. Written by
	// the installer scripts and rewritten by maybeNotifyUpdate.
	staxConfigFile = ".config.json"

	// agentsEmbedRoot is the directory name inside the embeddedAgents FS
	// AND the on-disk subdirectory name under the user-scope staxDir. The
	// dual role is intentional — one constant keeps embed source and disk
	// destination aligned. Must match the path in the `//go:embed all:agents`
	// directive in agents.go.
	agentsEmbedRoot = "agents"

	// staxLockFile pins the plan-tooling defaults inside the project-scope
	// staxDir. Treated as a lock file (Cargo.lock, package-lock.json
	// semantics): init writes it once and never refreshes it on
	// subsequent runs.
	staxLockFile = "_config.lock"

	// staxSystemsFile is the system registry inside the project-scope
	// staxDir — populated by the user as they add EARS systems. init seeds
	// it as a zero-byte placeholder if absent.
	staxSystemsFile = "_data_systems.yaml"

	// planFileExt is the on-disk extension every plan file carries. Pulled
	// out as a constant so plan.go's filename-format regexes, glob, and
	// suffix-trimming all reference the same value — adding a future
	// alternative extension (e.g. ".plan.md") is then a one-line change.
	planFileExt = ".md"
)

// agentTarget describes one downstream destination managed by `stax init`.
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
//	configSrc     — subdir under ~/<staxDir>/agents/ holding agent-specific
//	                files (e.g. "claude" for agents/claude/settings.json).
//	                Empty means this agent has no per-agent config to install.
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

// agentByKey returns the agentTargets row with the given `key`, or nil
// when no row matches. Callers that index into the registry by name
// (drift tests, ownedFiles, the few unit tests that reach for the Claude
// or Codex row directly) MUST use this helper instead of agentTargets[N]
// — the registry is sorted alphabetically by display name for the picker,
// so the integer offsets are not load-bearing and would silently drift
// if a future row is inserted in the middle.
func agentByKey(key string) *agentTarget {
	for i := range agentTargets {
		if agentTargets[i].key == key {
			return &agentTargets[i]
		}
	}
	return nil
}

// agentTargets is the registry consulted by `stax init` and `stax skills
// remove`. Rows are ordered alphabetically by display name (case-
// insensitive) so the interactive picker reads as an ordered list at
// every scope. Add a new agent by inserting a row at its alphabetical
// position; do NOT add per-agent special cases in the install/remove
// code. To add an agent that ships skills only (no per-agent config),
// leave configSrc and configRel empty.
//
// `key` is the value users type in `--agents <key>[,<key>...]` and the
// stable identifier the picker emits — keep it short, lowercase, and
// unique across the registry.
var agentTargets = []agentTarget{
	// Antigravity (antigravity.google) defaults to `.agents/skills/<name>/
	// SKILL.md` at workspace scope and `~/.gemini/antigravity/skills/<name>/
	// SKILL.md` at global scope, per antigravity.google/docs/skills (Nov 2026
	// docs surveyed via the official codelab + the in-product docs). The two
	// scope paths diverge — `~/.agents/skills` is the cross-agent fallback
	// Gemini-CLI honors but Antigravity explicitly does NOT, per Dazbo's
	// 2026 "confused about where to put your agent skills" rundown — so the
	// user-scope path needs a `userSkillsRel` override. The bundled tree
	// shape (`<name>/SKILL.md`) matches Antigravity's documented Skill
	// format (folder with a SKILL.md and optional `scripts/`, `examples/`,
	// `resources/` siblings), so no embed restructure is needed. Workspace-
	// scope `.agents/skills` co-locates with Codex/Copilot/Pi/omp; a
	// `--agents codex,antigravity` install collapses to one shared
	// `.agents/skills/` write at project scope. Skills-only for now —
	// Antigravity's hook surfaces aren't pinned to a public reference page
	// the way Claude's `settings.json` is, so configSrc/configRel stay
	// empty pending docs.
	{"antigravity", "Antigravity", ".agents/skills", ".gemini/antigravity/skills", "", ""},
	{"claude", "Claude Code", ".claude/skills", "", "claude", ".claude"},
	// Cline (cline.bot) reads skills from `.cline/skills/` at project scope
	// and `~/.cline/skills/` at user scope, per the official 2026 config
	// docs at docs.cline.bot/customization/overview. The cross-agent
	// `.agents/skills` path codex and copilot share is NOT a documented
	// cline lookup, so installing there would land files cline never
	// discovers. The bundled skill tree shape (`<name>/SKILL.md`) matches
	// cline's documented skill format — a Skill is a directory with a
	// SKILL.md inside — so no embed restructure is needed; the install
	// loop walks `agents/skills/<name>/` and lands each subtree under
	// `<root>/.cline/skills/<name>/` unchanged.
	// Skills-only for now — no settings.json / hooks file bundled for
	// cline; configSrc and configRel stay empty.
	{"cline", "Cline", ".cline/skills", "", "", ""},
	// Codex CLI scans .agents/skills/ at every level (cwd → repo root → $HOME),
	// per the cross-agent SKILL.md open standard. The legacy ~/.codex/skills
	// is also recognized at user scope but not at project scope, so .agents
	// is the one path that works in both modes. Per-agent config (hooks.json,
	// config.toml, etc.) still lives under .codex/ — see Codex docs:
	// https://developers.openai.com/codex/hooks for the lookup order.
	{"codex", "Codex CLI", ".agents/skills", "", "codex", ".codex"},
	// Continue (continue.dev) reads skills from `.continue/skills/` at
	// project scope and `~/.continue/skills/` at user scope, per the
	// continue.dev customization docs (the IDE extension scans both
	// roots on session start). Symmetric across scopes — no
	// userSkillsRel override needed. Continue does NOT honor the
	// cross-agent `.agents/skills` path, so installing there would
	// land files Continue never discovers; the install must use
	// `.continue/skills` exclusively. Skills-only — Continue's
	// settings live at `~/.continue/config.yaml` and are user-owned
	// end-to-end, outside the stax install scope.
	{"continue", "Continue", ".continue/skills", "", "", ""},
	// Cursor reads skills from `.agents/skills/` at workspace scope
	// (the cross-agent open spec path, shared with Codex/Copilot/Pi/
	// omp/Antigravity) and from `~/.cursor/skills/` at global scope —
	// Cursor does NOT honor the cross-agent `~/.agents/skills`
	// fallback at user scope, same divergence shape as Antigravity.
	// Needs a `userSkillsRel` override for that reason. The install
	// is skills-only; Cursor's settings (`~/.cursor/settings.json`,
	// MCP config, the cursor-agent hosted backend auth via
	// CURSOR_API_KEY) are all user-owned end-to-end and outside the
	// stax install scope.
	{"cursor", "Cursor", ".agents/skills", ".cursor/skills", "", ""},
	// GitHub Copilot CLI reads skills from `.agents/skills/`, `.claude/skills/`,
	// or `.github/skills/` at project scope, and `~/.copilot/skills/` or
	// `~/.agents/skills/` at user scope (per Copilot CLI's May 2026 docs at
	// docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills).
	// We use `.agents/skills` at BOTH scopes — the cross-agent open spec
	// path. Reasons:
	//   1. agents/skills/scope/SKILL.md and agents/skills/ship/SKILL.md
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
	// Kilo Code (kilocode.ai) reads skills from `.kilocode/skills/` at
	// project scope and `~/.kilocode/skills/` at user scope, per
	// kilocode.ai's customization docs and the published `.kilocode/`
	// config tree convention. The cross-agent `.agents/skills` path is
	// NOT a documented Kilo lookup, so installing there would land
	// files Kilo never discovers. Symmetric across scopes — no
	// userSkillsRel override needed. Skills-only; Kilo's settings live
	// in `~/.kilocode/` end-to-end and are user-owned outside the stax
	// install scope.
	{"kilo", "Kilo Code", ".kilocode/skills", "", "", ""},
	// omp (oh-my-pi, omp.sh / can1357/oh-my-pi) is a TS coding agent
	// that registers a documented `agents` skill provider at priority
	// 70 — see oh-my-pi/docs/skills.md "priority 70 group (in
	// registration order): claude-plugins, agents, codex" and the
	// matching source at packages/coding-agent/src/discovery/agents.ts.
	// That provider walks `.agent/` and `.agents/` (both names) at:
	//   project scope → walk up from cwd to repoRoot, scanning
	//                   `<dir>/.agents/skills/` at each ancestor
	//   user scope    → `$HOME/.agents/skills/`
	//
	// We pin to `.agents/skills` at both scopes — the cross-agent open
	// spec path, identical to Codex's project-scope path and Copilot
	// CLI's officially-documented add-skills location at both scopes.
	// Reasons:
	//   1. Symmetric across scopes — no userSkillsRel override needed,
	//      `omp -h` does not introduce a user-scope/project-scope
	//      asymmetry for this provider (unlike the native priority-100
	//      `.omp` provider where user-scope lives under `.omp/agent/`).
	//   2. Cross-platform — node:path joins resolve to `.agents\skills`
	//      on Windows automatically (omp's binary is officially
	//      "macOS, Linux, Windows, no WSL bridge" per README).
	//   3. Stays out of omp's private session-storage tree
	//      (`~/.omp/agent/`, owned end-to-end by omp's own runtime —
	//      writing into it is a layering violation).
	//   4. Idempotent with Codex/Copilot/Pi: `--agents codex,copilot,pi,omp`
	//      collapses to one shared `.agents/skills/` install plus
	//      Codex's own `.codex/hooks.json`.
	//
	// Skills-only — omp's user settings live at `~/.omp/config.yml`
	// (interactive Settings → Memory tab) and its model registry at
	// `~/.omp/agent/models.yml`. Both are user-owned end-to-end and
	// outside the stax install scope.
	{"omp", "Oh My Pi", ".agents/skills", "", "", ""},
	// OpenCode resolves slash commands from `.opencode/{command,commands}/**/*.md`
	// at project scope and `~/.config/opencode/commands/` at user scope.
	// The lookup keys off the file's frontmatter `name:` (the path-derived
	// fallback is used only when frontmatter omits `name:`), so a stax
	// install at `.opencode/commands/scope/SKILL.md` with `name: scope`
	// registers a command callable as both `/scope` in the TUI and
	// `opencode run --command scope ...` from the CLI (sst/opencode
	// PR #2348). The bundled tree shape (`<command>/SKILL.md` rather than
	// flat `<command>.md`) matches Claude/Codex for parity across agents.
	// No per-agent config is bundled for OpenCode yet (auth + provider
	// routing live outside the install scope, in `~/.local/share/opencode/`).
	{"opencode", "OpenCode", ".opencode/commands", "", "", ""},
	// Pi (pi.dev — @earendil-works/pi-coding-agent) reads skills from
	// `.agents/skills/` walking up from cwd at project scope and from
	// `~/.agents/skills/` at user scope (one of two documented user-scope
	// locations alongside `~/.pi/agent/skills/`, per pi-mono's
	// packages/coding-agent/docs/skills.md). We use the cross-agent
	// `.agents/skills` path at both scopes — same as Codex and Copilot —
	// so a single install reaches every "agents-standard" tool on the
	// machine. Pi's CLI command parser resolves `/skill:<name>` in print
	// mode by reading SKILL.md frontmatter `name:`, so the bundled
	// `scope` and `ship` skills register as `/skill:scope` and
	// `/skill:ship` in both interactive (`pi`) and headless (`pi -p`)
	// invocations without any per-agent config file. configSrc/configRel
	// stay empty — no pi-specific config bundled today; pi looks for
	// `~/.pi/agent/AGENTS.md` and `~/.pi/agent/settings.json` if a user
	// adds them, which is outside the scope of stax's install.
	{"pi", "Pi", ".agents/skills", "", "", ""},
	// Zed (zed.dev) reads skills from `.agents/skills/` at workspace
	// scope and from `~/.agents/skills/` at global scope — Zed
	// explicitly honors the cross-agent open spec at BOTH scopes per
	// zed.dev's "agent panel skills" docs, making it the symmetric
	// case (no userSkillsRel override). Install collapses with
	// Codex/Copilot/Pi/omp/Cursor-workspace/Antigravity-workspace at
	// project scope, and with Codex/Copilot/Pi/omp at user scope —
	// a single `--agents codex,zed` install writes one shared
	// `.agents/skills/` directory at each scope. Skills-only; Zed's
	// settings live at `~/.config/zed/settings.json` (Linux/macOS
	// XDG), `%APPDATA%\Zed\settings.json` (Windows), or
	// `$FLATPAK_XDG_CONFIG_HOME/zed/settings.json` (Flatpak), all
	// user-owned end-to-end and outside the stax install scope.
	{"zed", "Zed", ".agents/skills", "", "", ""},
}

// skillsSubdir is the directory inside ~/<staxDir>/agents/ that holds the
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
// `agents/codex/hooks.json`) under which stax's shipped hook records
// live. The files themselves are user-owned end-to-end; what stax owns
// are individual leaf records inside the arrays nested under this key.
//
// `stax skills remove` consults this constant to scope its un-merge:
// only entries underneath this property are candidates for subtraction,
// and even then only when they deep-equal a record in the currently
// bundled file. Renaming the key in a future config schema = update
// this constant + the matching property in `agents/<agent>/*.json`.
const configHooksKey = "hooks"

// Plan-tooling defaults pinned into <staxDir>/<staxLockFile> by
// writePlansScaffold during `stax init`. The `stax plans` subcommands read
// these values from the lock file at runtime; the binary is the standard
// source for new projects while existing projects keep whatever they
// pinned on their first `stax init`. Bump these numbers to change behavior
// going forward without disturbing prior installs.
const (
	// defaultPrefixWidth is the zero-padded width of plan-file numeric
	// prefixes (e.g. width 4 → "0001-foo.md"). Bump to widen prefixes.
	defaultPrefixWidth = 4

	// defaultMaxPlanLines is the line-count ceiling `stax plans lint`
	// enforces on a single plan file (frontmatter + body, inclusive).
	defaultMaxPlanLines = 30

	// plansListOverflowThreshold is the row count above which
	// `stax plans list` activates the optional `--overflow-keywords` narrow.
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
// for contributors browsing GitHub) that have no business in ~/<staxDir>/agents.
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
	skillScopeDir = "scope"
	skillShipDir  = "ship"
)

// skillManifestFile is the manifest filename every bundled skill ships
// under its directory (cross-agent SKILL.md open standard — Claude Code,
// Codex CLI, and Gemini all look for this exact name). Pulled into a
// constant so tests that round-trip files out of the embed don't violate
// the "no inline path literals in Go source" rule.
const skillManifestFile = "SKILL.md"

// ownedSkills is the standard, exhaustive list of skill directory names
// the binary ships and is allowed to delete. `stax skills remove` uses this
// as a strict allowlist — a folder named anything else under .claude/skills
// or .agents/skills is the user's, never ours, and is always left alone.
//
// Keep this in sync with the directories under agents/skills/ in the repo.
// Adding a new bundled skill = adding a `skill*Dir` constant above and
// appending it here. The embed.FS-driven install pulls in whatever is on
// disk; this list is the matching allowlist for removal.
var ownedSkills = []string{
	skillScopeDir,
	skillShipDir,
}

// ownedFiles is the exhaustive list of files (relative to the install scope
// root) that `stax init` may have written. None of them carry a marker, and
// each `init` run leaves them alone if they already exist — so removal must
// be conservative (today: not automated). Recorded here so the inventory
// of "what stax touches on disk" lives in one place, even though no code
// path currently iterates it (hence the nolint below).
//
//nolint:unused // documentation registry; will be surfaced in `stax skills remove` UX.
var ownedFiles = []string{
	// Plan-tooling scaffold seeded by writePlansScaffold (project scope only).
	staxDir + "/" + staxSystemsFile,
	staxDir + "/" + staxLockFile,
	// Per-agent config files copied from agents/<agent>/ by installAgentConfig.
	// Empty-target-only writes: an existing file is preserved.
	agentByKey("claude").configRel + "/settings.json",
}

// Update-check settings — read by maybeNotifyUpdate / fetchLatestVersion.
// All values are package constants so the behavior can be reasoned about
// without inspecting individual call sites.
const (
	// updateCheckInterval bounds how often the CLI is willing to probe
	// GitHub for a new release. 1 hour balances "fresh installs see a
	// release that landed an hour ago" against the 60-req/hour
	// unauthenticated GitHub API limit (per IP, shared across the whole
	// CLI population on a given network — well under cap for typical
	// solo / small-team use). The installer seeds `last_checked` to
	// install time, so the first nudge fires at most one hour after
	// install regardless of how long ago the binary was downloaded.
	updateCheckInterval = time.Hour

	// updateHTTPTimeout is the wall-clock cap on the latest-release lookup.
	// Kept short — the check is opportunistic and must never delay the
	// user's main command on a slow network.
	updateHTTPTimeout = 3 * time.Second

	// releasesAPIURL is the unauthenticated endpoint that returns the
	// most recent release's metadata. Only the `tag_name` field is read.
	releasesAPIURL = "https://api.github.com/repos/stackific/stax/releases/latest"

	// installShURL / installPS1URL are the standard install-script URLs
	// surfaced to the user in the "update available" nudge. The README
	// and docs/public/getting-started.md should match these strings.
	installShURL  = "https://stackific.com/stax/INSTALL.sh"
	installPS1URL = "https://stackific.com/stax/INSTALL.ps1"
)

// Local-server settings — read by runServer / runDefault. The listen
// address is pinned to the loopback interface so the server never
// accepts connections from elsewhere on the network: this is a per-user
// CLI assistant, not a shared service. Port 7829 is the documented
// preferred port; when it is already in use, listenWithFallback walks
// forward through serverPortFallbackAttempts adjacent ports (7830,
// 7831, …) so a second concurrent `stax` invocation lands on a free
// port rather than failing with "address already in use".
const (
	// serverListenAddr is the preferred host:port the bare-stax HTTP
	// server binds first. The bind host is the literal `127.0.0.1` (not
	// `localhost`) so the listen is deterministic — `net.Listen("tcp",
	// "localhost:N")` would resolve through DNS / /etc/hosts and land
	// on whichever stack the resolver picks first, which differs across
	// macOS, Linux, and WSL. Pinning the IPv4 loopback removes that
	// variability and rules out an accidental bind to 0.0.0.0 if a
	// future config slips a hostname through.
	serverListenAddr = "127.0.0.1:7829"

	// serverDisplayURL is the http:// URL printed in help text, the
	// banner stdout line, and handed off to the OS-default browser.
	// Uses `localhost` rather than `127.0.0.1` because browsers treat
	// the literal `localhost` as a secure context by default (per the
	// W3C secure-contexts spec) and it reads better in logs. The split
	// between bind host and display host is intentional — see
	// serverListenAddr above for the rationale on each side.
	serverDisplayURL = "http://localhost:7829"

	// serverPortFallbackAttempts bounds how many adjacent ports the
	// listener will try after the preferred port fails with EADDRINUSE.
	// Stops after 100 attempts (7830..7929 inclusive) so a permanently
	// claimed range surfaces as a clear error rather than an infinite
	// loop, while still leaving plenty of headroom for a dozen
	// concurrent stax instances on the same machine.
	serverPortFallbackAttempts = 100

	// serverReadHeaderTimeout caps how long the server will wait for a
	// client's request headers. Short, fixed value because the server
	// serves only its own narrow API (no slow-client uploads); a hung
	// client must not pin a goroutine indefinitely.
	serverReadHeaderTimeout = 5 * time.Second

	// serverShutdownTimeout bounds the graceful-shutdown wait after
	// SIGINT/SIGTERM. Five seconds is plenty for the in-flight handlers
	// (a JSON encode and a YAML walk) to drain; longer would make
	// Ctrl-C feel sluggish on a hung handler.
	serverShutdownTimeout = 5 * time.Second
)

// API path constants. Surfaced as named constants so the handler
// registration (server.go) and the e2e probes (scripts/e2e_test.sh)
// can both reference one source of truth — renaming an endpoint is
// then a one-line edit here plus the mirror in the shell harness.
const (
	apiHelloPath   = "/api/hello"
	apiSystemsPath = "/api/systems"
)
