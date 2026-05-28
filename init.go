// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/mattn/go-isatty"
)

// initScope is the user's choice between "this project" and "all projects".
// Encoding it as an enum (rather than a bool) leaves room for future scopes
// (e.g. workspace-level for multi-project repos) without breaking call sites.
type initScope int

// Scope values are stable identifiers — promptScope parses user input as
// "1" or "2" matching these. Do not renumber without auditing the prompt.
const (
	scopeProject initScope = 1
	scopeUser    initScope = 2
)

// runInit is the entry point for `x-x init`. The flow:
//  1. Print intro line.
//  2. Prompt for scope (project vs user).
//  3. Ensure ~/.x-x/agents/ is materialized (lazy bootstrap).
//  4. Enumerate skills under ~/.x-x/agents/skills/.
//  5. For each registered agent: install skills + per-agent config files.
//  6. Drop the .x-plans/ scaffold (idempotent — only writes missing files).
//
// Per-skill or per-target failures print to stderr but don't abort the
// whole run, so a single permissions glitch on one agent's dir doesn't
// strand the others.
func runInit(args []string) {
	flags := flag.NewFlagSet("init", flag.ExitOnError)
	// --agents preselects which downstream agents get the skill install,
	// bypassing the interactive picker. Comma-separated, accumulates across
	// repeated occurrences. Valid keys come from `agentTargets[*].key`.
	var agentsFlag stringSliceFlag
	flags.Var(&agentsFlag, "agents", "comma-separated agent keys (e.g. claude,codex) — skip the agents picker")
	// --scope makes the interactive prompt skippable for CI / scripted use.
	// Accepts "project" or "user"; any other value is rejected explicitly.
	// Leave blank to fall back to the interactive flow.
	scopeFlag := flags.String("scope", "", "project|user — skip the scope picker")
	// --prefix-width / --max-plan-lines / --review-per are the
	// non-interactive twins of the three plan-tooling prompts. Pass them
	// (alongside --agents and --scope) to drive `x-x init` end-to-end
	// without touching the wizard or line prompts.
	prefixWidthFlag := flags.Int("prefix-width", 0, "zero-padded width for plan prefixes (positive integer; default seeds the project default)")
	maxPlanLinesFlag := flags.Int("max-plan-lines", 0, "line-count ceiling enforced by `x-x plans lint` (positive integer; default seeds the project default)")
	reviewPerFlag := flags.String("review-per", "", "task|plan — pause for review after every task or every plan")
	flags.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: x-x init [--agents claude,codex] [--scope project|user]")
		fmt.Fprintln(os.Stderr, "             [--prefix-width N] [--max-plan-lines N] [--review-per task|plan]")
		fmt.Fprintln(os.Stderr, "  Installs the bundled agent skill library for Claude Code and Codex CLI.")
	}
	_ = flags.Parse(args)

	// Validate every flag AS PASSED — the zero-value "unset" encoding would
	// otherwise let `--prefix-width=-1`, `--max-plan-lines=0`, `--agents=`,
	// or `--review-per ''` slip through and silently fall back to defaults
	// (or, worse, re-prompt the user in CI). flag.Visit walks only flags
	// that were actually set on the command line — exactly the set we want
	// to check.
	validateInitFlagsOrExit(flags, prefixWidthFlag, maxPlanLinesFlag, &agentsFlag, reviewPerFlag)

	cwd, err := os.Getwd()
	if err != nil {
		// os.Getwd can fail in obscure cases (deleted cwd, permissions).
		// We can't do anything useful without it — bail.
		exitErr(err)
	}
	// Refuse re-init on a fully-initialized project. checkProject is the
	// same check `requireProject` uses, so a directory that passes the
	// project-scope marker check elsewhere triggers this refusal here. Re-running
	// init on a fresh / partially-initialized directory still works,
	// which is what writePlansScaffold's writeIfAbsent semantics rely on.
	// The check runs AFTER flag validation so a real usage error (bad flag,
	// stray positional) still wins the diagnostic.
	if checkProject() == nil {
		fmt.Fprintln(os.Stderr, projectAlreadyInitBanner)
		os.Exit(2)
	}
	fmt.Printf("Setting up x-x in %s\n\n", cwd)

	cfg, err := resolveInitConfig(initFlags{
		agents:       agentsFlag,
		scope:        *scopeFlag,
		prefixWidth:  *prefixWidthFlag,
		maxPlanLines: *maxPlanLinesFlag,
		reviewPer:    *reviewPerFlag,
	}, os.Stdin, stdinIsTTY(os.Stdin))
	if err != nil {
		exitErr(err)
	}

	// Source must exist before we can read skill names from it. This is
	// a no-op when ~/.x-x/agents/ already exists; otherwise it materializes
	// the embed.FS to disk on the fly.
	if err := ensureBundledAgents(); err != nil {
		exitErr(err)
	}
	agentsRoot, err := agentsTarget()
	if err != nil {
		exitErr(err)
	}
	// Skills live in ~/.x-x/agents/skills/. Per-agent config (claude/,
	// codex/, …) lives in sibling directories under agentsRoot — see
	// installForTarget for the per-agent config branch.
	skillsSource := filepath.Join(agentsRoot, skillsSubdir)
	skills, err := listSkills(skillsSource)
	if err != nil {
		exitErr(err)
	}
	if len(skills) == 0 {
		// Bundled-empty case. Not an error — just nothing to do.
		fmt.Fprintln(os.Stderr, "no skills to install")
		return
	}

	scopeRoot, err := scopeRootFor(cfg.scope, cwd)
	if err != nil {
		exitErr(err)
	}

	// Link strategy is decided once per run:
	//   user scope + non-Windows → symlinks (auto-refresh when
	//     ~/.x-x/agents/ updates)
	//   anything else (Windows, project scope) → copies
	// Windows is excluded from symlinks because os.Symlink requires
	// Developer Mode or admin elevation by default. Project scope is
	// excluded because the resulting dir often gets committed to git;
	// symlinks pointing into ~/.x-x/ would break for teammates.
	useSymlink := cfg.scope == scopeUser && runtime.GOOS != "windows"
	strategy := "copy"
	if useSymlink {
		strategy = "symlink"
	}
	fmt.Printf("Installing %d skill(s) for %d agent(s) (%s)...\n", len(skills), len(cfg.agents), strategy)

	// Walk the selected subset of the registry. Agents not chosen at the
	// picker (or omitted from --agents) are silently skipped — their
	// install dirs are left untouched.
	for i := range cfg.agents {
		installForTarget(&cfg.agents[i], skills, scopeRoot, skillsSource, agentsRoot, useSymlink, cfg.scope)
	}

	// `.x-plans/` scaffold lives in cwd regardless of scope. Scope only
	// decides where SKILLS land (project tree vs $HOME); the project marker
	// check keyed on `<cwd>/.x-plans/_config.lock` is what makes cwd usable
	// with `/x-plan`, `/x-x`, and the `x-x plans *` CLI subcommands. A
	// user-scope install that left cwd un-scaffolded produced skills with
	// nowhere to anchor plans — every subsequent command tripped the
	// `not an x-x project` check. Writing the scaffold under both scopes
	// keeps cwd a real x-x project either way.
	//
	// Failures here are non-fatal — they downgrade to a warning because
	// the skill install (the primary purpose) already succeeded.
	if err := writePlansScaffold(cwd, cfg); err != nil {
		fmt.Fprintf(os.Stderr, "warning: %v\n", err)
	}

	fmt.Println("\nDone.")
	// Plan files are first-class repo content (frontmatter + EARS tasks),
	// not local state. Nudge the user to commit them so the team shares
	// the same plan history. Phrased as a tip rather than auto-editing
	// .gitignore so we never touch git config behind the user's back.
	fmt.Printf("\nTip: commit %s/ to git so your team shares plan history.\n", plansDir)

	// Anonymous-usage ping. Fires at the end of the happy path so a
	// fatal error earlier in runInit (which exits via exitErr) doesn't
	// produce a "completed init" event the install never actually
	// reached. Opt-out via DO_NOT_TRACK / DISABLE_TELEMETRY; see
	// docs/internal/telemetry.md for the full schema + privacy notes.
	agentKeys := make([]string, len(cfg.agents))
	for i, a := range cfg.agents {
		agentKeys[i] = a.key
	}
	scopeLabel := "project"
	if cfg.scope == scopeUser {
		scopeLabel = "user"
	}
	track("init", telemetryEvent{
		"scope":       scopeLabel,
		"agents":      strings.Join(agentKeys, ","),
		"agent_count": strconv.Itoa(len(cfg.agents)),
		"skill_count": strconv.Itoa(len(skills)),
	})
	flushTelemetry()
}

// validateInitFlagsOrExit is the runInit-facing wrapper around
// validateInitFlags: prints the first violation via exitErr and never
// returns. Extracted into a one-liner so runInit's body stays under the
// linter's cyclomatic-complexity ceiling — the actual validation logic
// (and its testable error-returning form) lives in validateInitFlags.
func validateInitFlagsOrExit(flags *flag.FlagSet, prefixWidth, maxPlanLines *int, agents *stringSliceFlag, reviewPer *string) {
	if err := validateInitFlags(flags, prefixWidth, maxPlanLines, agents, reviewPer); err != nil {
		exitErr(err)
	}
}

// validateInitFlags rejects invalid values for any --init flag the user
// actually passed (via flag.Visit, which walks only set flags). The
// zero-value "unset" encoding would otherwise let an empty --agents= or
// --review-per fall through to f.complete() == false, which silently
// re-prompts the user — fine for an unset flag, wrong for one the user
// explicitly passed with an empty value. Returns the first violation as
// an error so runInit (and unit tests) can drive the failure path.
func validateInitFlags(flags *flag.FlagSet, prefixWidth, maxPlanLines *int, agents *stringSliceFlag, reviewPer *string) error {
	var firstErr error
	flags.Visit(func(fl *flag.Flag) {
		if firstErr != nil {
			return
		}
		switch fl.Name {
		case "prefix-width":
			if *prefixWidth <= 0 {
				firstErr = fmt.Errorf("--prefix-width must be positive, got %d", *prefixWidth)
			}
		case "max-plan-lines":
			if *maxPlanLines <= 0 {
				firstErr = fmt.Errorf("--max-plan-lines must be positive, got %d", *maxPlanLines)
			}
		case "agents":
			if len(*agents) == 0 {
				firstErr = fmt.Errorf("--agents: at least one agent required")
			}
		case "review-per":
			if *reviewPer == "" {
				firstErr = fmt.Errorf("invalid --review-per: %q (expected %s or %s)", *reviewPer, reviewPerTask, reviewPerPlan)
			}
		}
	})
	return firstErr
}

// initFlags bundles the raw CLI flag values for `x-x init`. Each field is
// "unset"-encoded with its zero value (empty string, nil slice, 0 int) so
// resolveInitConfig can distinguish "user passed a flag" from "user left
// it for the prompt to fill in".
type initFlags struct {
	agents       []string // raw --agents values (empty = ask)
	scope        string   // raw --scope value ("" = ask)
	prefixWidth  int      // 0 = ask
	maxPlanLines int      // 0 = ask
	reviewPer    string   // "" = ask
}

// initConfig is the post-resolution, fully-typed set of choices the rest
// of runInit needs. Every field is guaranteed valid by the time
// resolveInitConfig returns nil.
type initConfig struct {
	agents       []agentTarget
	scope        initScope
	prefixWidth  int
	maxPlanLines int
	reviewPer    string
}

// resolveInitConfig collects every value runInit needs to perform the
// install. Three branches:
//
//  1. Every flag set → return the typed config directly, never prompt.
//     This is the true non-interactive path (CI / scripted installs).
//  2. Stdin is a TTY → run the huh wizard, pre-populating any flag values
//     the user already passed. The wizard supports back-navigation between
//     groups (Shift+Tab) so the user can revise prior selections before
//     final submission.
//  3. Otherwise → run line prompts for the unset values. Keeps
//     `printf "..." | x-x init` working in headless / piped contexts
//     (CI, AGENTS.md test cases).
//
// `useTUI` is a parameter (rather than computed internally) so tests can
// pin the line-prompt branch without needing a real terminal.
func resolveInitConfig(f initFlags, in io.Reader, useTUI bool) (initConfig, error) {
	if f.complete() {
		return f.toConfig()
	}
	if useTUI {
		return runHuhWizard(f)
	}
	return runLinePrompts(f, in)
}

// complete reports whether every field is set; used by resolveInitConfig
// to short-circuit the prompt path. "Set" means a non-zero value — see
// the field-level comments on initFlags for the encoding.
func (f initFlags) complete() bool {
	return len(f.agents) > 0 &&
		f.scope != "" &&
		f.prefixWidth > 0 &&
		f.maxPlanLines > 0 &&
		f.reviewPer != ""
}

// toConfig converts a fully-populated initFlags into the typed initConfig,
// returning a usage-style error if any value fails validation. Only called
// from the all-flags-set branch of resolveInitConfig.
func (f initFlags) toConfig() (initConfig, error) {
	agents, err := resolveAgentsFromKeys(f.agents)
	if err != nil {
		return initConfig{}, err
	}
	scope, err := parseScope(f.scope)
	if err != nil {
		return initConfig{}, err
	}
	review, err := parseReviewPer(f.reviewPer)
	if err != nil {
		return initConfig{}, err
	}
	if f.prefixWidth <= 0 {
		return initConfig{}, fmt.Errorf("--prefix-width must be positive, got %d", f.prefixWidth)
	}
	if f.maxPlanLines <= 0 {
		return initConfig{}, fmt.Errorf("--max-plan-lines must be positive, got %d", f.maxPlanLines)
	}
	return initConfig{
		agents:       agents,
		scope:        scope,
		prefixWidth:  f.prefixWidth,
		maxPlanLines: f.maxPlanLines,
		reviewPer:    review,
	}, nil
}

// runLinePrompts is the non-TTY branch: for each unset field on `f`, ask
// the matching line prompt against `in`. Values supplied via flag are
// passed through verbatim (only validated). One buffered reader is shared
// across every prompt so read-ahead does not eat bytes the next prompt
// still needs.
func runLinePrompts(f initFlags, in io.Reader) (initConfig, error) {
	r := bufReader(in)
	cfg := initConfig{
		prefixWidth:  f.prefixWidth,
		maxPlanLines: f.maxPlanLines,
		reviewPer:    f.reviewPer,
	}
	var err error

	// agents + scope already have flag-vs-prompt resolvers; reuse them so
	// the "flag wins, else ask" rule lives in exactly one place per field.
	if cfg.agents, err = resolveAgents(f.agents, r); err != nil {
		return initConfig{}, err
	}
	if cfg.scope, err = resolveScope(f.scope, r); err != nil {
		return initConfig{}, err
	}

	if cfg.prefixWidth <= 0 {
		cfg.prefixWidth, err = promptPrefixWidth(r)
		if err != nil {
			return initConfig{}, err
		}
	}

	if cfg.maxPlanLines <= 0 {
		cfg.maxPlanLines, err = promptMaxPlanLines(r)
		if err != nil {
			return initConfig{}, err
		}
	}

	if cfg.reviewPer == "" {
		cfg.reviewPer, err = promptReviewPer(r)
	} else {
		cfg.reviewPer, err = parseReviewPer(cfg.reviewPer)
	}
	if err != nil {
		return initConfig{}, err
	}

	return cfg, nil
}

// runHuhWizard is the TTY branch: render a multi-step huh.Form, pre-
// populating each field from the matching flag (or the project default
// when the flag is unset). Users can revise prior selections at any time
// by pressing Shift+Tab to move backwards between groups; Enter on the
// final group submits.
func runHuhWizard(f initFlags) (initConfig, error) {
	selectedAgentKeys := append([]string(nil), f.agents...)
	if len(selectedAgentKeys) == 0 {
		selectedAgentKeys = make([]string, 0, len(agentTargets))
		for _, t := range agentTargets {
			selectedAgentKeys = append(selectedAgentKeys, t.key)
		}
	}
	scope := scopeProject
	if f.scope == "user" {
		scope = scopeUser
	}
	prefixWidth := defaultPrefixWidth
	if f.prefixWidth > 0 {
		prefixWidth = f.prefixWidth
	}
	maxPlanLines := defaultMaxPlanLines
	if f.maxPlanLines > 0 {
		maxPlanLines = f.maxPlanLines
	}
	reviewPer := defaultReviewPer
	if f.reviewPer != "" {
		reviewPer = f.reviewPer
	}

	// huh's Input value bindings are strings; the integer fields use
	// dedicated string vars and get parsed back after the form returns.
	prefixWidthStr := strconv.Itoa(prefixWidth)
	maxPlanLinesStr := strconv.Itoa(maxPlanLines)

	agentOpts := make([]huh.Option[string], len(agentTargets))
	for i, t := range agentTargets {
		agentOpts[i] = huh.NewOption(t.name, t.key)
	}

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Which agents should be installed?").
				Description("Space toggles a row. Defaults to every registered agent.").
				Options(agentOpts...).
				Value(&selectedAgentKeys).
				Validate(func(v []string) error {
					if len(v) == 0 {
						return fmt.Errorf("pick at least one agent")
					}
					return nil
				}),
		),
		huh.NewGroup(
			huh.NewSelect[initScope]().
				Title("Where should agent skills be installed?").
				Options(
					huh.NewOption("This project only", scopeProject),
					huh.NewOption("All my projects (user scope)", scopeUser),
				).
				Value(&scope),
		),
		huh.NewGroup(
			huh.NewInput().
				Title("Prefix width for plan files").
				Description("Zero-padded width for plan filenames (e.g. width 4 → 0001-foo.md). Higher values give more headroom before plan numbers run out.").
				Value(&prefixWidthStr).
				Validate(validatePositiveInt),
		),
		huh.NewGroup(
			huh.NewInput().
				Title("Maximum lines per plan").
				Description("Keeps AI agents on a short leash: forces them to split sprawling work into smaller, reviewable plans.").
				Value(&maxPlanLinesStr).
				Validate(validatePositiveInt),
		),
		huh.NewGroup(
			huh.NewSelect[string]().
				Title("Pause for review after every…").
				Description("`task` — review each EARS criterion as the planner finishes it (tight loop, more interruptions).  `plan` — review at the end of each plan (looser loop, larger diffs).").
				Options(
					huh.NewOption(reviewPerTask+" — tight feedback loop", reviewPerTask),
					huh.NewOption(reviewPerPlan+" — review only at plan boundaries", reviewPerPlan),
				).
				Value(&reviewPer),
		),
	)

	if err := form.Run(); err != nil {
		return initConfig{}, err
	}

	pw, err := strconv.Atoi(strings.TrimSpace(prefixWidthStr))
	if err != nil || pw <= 0 {
		return initConfig{}, fmt.Errorf("invalid prefix-width from wizard: %q", prefixWidthStr)
	}
	ml, err := strconv.Atoi(strings.TrimSpace(maxPlanLinesStr))
	if err != nil || ml <= 0 {
		return initConfig{}, fmt.Errorf("invalid max-plan-lines from wizard: %q", maxPlanLinesStr)
	}
	agents, err := resolveAgentsFromKeys(selectedAgentKeys)
	if err != nil {
		return initConfig{}, err
	}
	return initConfig{
		agents:       agents,
		scope:        scope,
		prefixWidth:  pw,
		maxPlanLines: ml,
		reviewPer:    reviewPer,
	}, nil
}

// validatePositiveInt is the huh.Input validator shared by the
// prefix-width and max-plan-lines fields. Strings only — caller parses
// the int after form.Run returns.
func validatePositiveInt(s string) error {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return fmt.Errorf("must be an integer")
	}
	if n <= 0 {
		return fmt.Errorf("must be positive")
	}
	return nil
}

// stdinIsTTY reports whether the given file (typically os.Stdin) is
// attached to a terminal. The huh wizard requires a real terminal;
// piped / redirected stdin falls through to the line-prompt branch.
func stdinIsTTY(f *os.File) bool {
	return isatty.IsTerminal(f.Fd())
}

// writePlansScaffold creates the project-local .x-plans/ directory and seeds
// the two files that the plan tooling expects to find on disk:
//
//	_data_systems.yaml — empty placeholder; populated by the user as systems are added
//	_config.lock  — plan-tooling pins (prefix_width, max_plan_lines, review_per)
//
// Both files are only written when ABSENT so existing content survives
// re-runs. _config.lock specifically acts as a pin: re-running init
// never refreshes it, matching the conventional lock-file semantics
// (Cargo.lock, package-lock.json, etc.) — the values stored come from
// cfg, which carries either the user's wizard / flag choices or the
// project defaults.
func writePlansScaffold(cwd string, cfg initConfig) error {
	dir := filepath.Join(cwd, plansDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create %s: %w", dir, err)
	}
	// Empty placeholder — the plan tooling populates this as the project
	// grows. Writing nil content creates a zero-byte file.
	if err := writeIfAbsent(filepath.Join(dir, plansSystemsFile), nil); err != nil {
		return err
	}
	// Inline anonymous struct: the lock file is JSON-formatted, but the only
	// place we materialize it is here, so a dedicated type would be overkill.
	lock := struct {
		PrefixWidth  int    `json:"prefix_width"`
		MaxPlanLines int    `json:"max_plan_lines"`
		ReviewPer    string `json:"review_per"`
	}{
		PrefixWidth:  cfg.prefixWidth,
		MaxPlanLines: cfg.maxPlanLines,
		ReviewPer:    cfg.reviewPer,
	}
	body, err := json.MarshalIndent(lock, "", "  ")
	if err != nil {
		return err
	}
	// Append a trailing newline so the file matches standard text-file
	// conventions (every line ends with \n).
	body = append(body, '\n')
	return writeIfAbsent(filepath.Join(dir, plansConfigLockFile), body)
}

// writeIfAbsent is the "create only if missing" primitive. Stat first;
// if the file exists, return nil and leave it alone. If it doesn't,
// write the given content with 0o600 perms. Used by writePlansScaffold.
func writeIfAbsent(path string, content []byte) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	return os.WriteFile(path, content, 0o600)
}

// installForTarget handles one agent in the registry: its skills first,
// then any agent-specific config files. Per-target failures print to
// stderr but don't abort the run — other targets still get processed.
//
// The function takes everything it needs as arguments (no global state)
// so it can be reasoned about and tested in isolation if a test ever
// gets written.
//
// `scope` is consulted via t.skillsRelFor so agents with a per-scope
// skill path (e.g. Copilot CLI: `.agents/skills` at project,
// `~/.copilot/skills` at user) land in the right directory.
func installForTarget(t *agentTarget, skills []string, scopeRoot, skillsSource, agentsRoot string, useSymlink bool, scope initScope) {
	// Pass 1: skills. Each skill lives at <scopeRoot>/<skillsRel>/<skill>/.
	skillsDir := filepath.Join(scopeRoot, t.skillsRelFor(scope))
	if err := os.MkdirAll(skillsDir, 0o700); err != nil {
		// Can't even create the parent skills dir for this agent.
		// Log + skip — other agents may still succeed.
		fmt.Fprintf(os.Stderr, "  %-13s skipped: %v\n", t.name, err)
		return
	}
	fmt.Printf("  %-13s %s\n", t.name, skillsDir)
	for _, skill := range skills {
		src := filepath.Join(skillsSource, skill)
		dest := filepath.Join(skillsDir, skill)
		// Per-skill error is logged but does not abort. This is important:
		// a single skill collision (user-owned dir) shouldn't prevent
		// other skills from installing.
		if err := installSkill(src, dest, useSymlink); err != nil {
			fmt.Fprintf(os.Stderr, "    %s: %v\n", skill, err)
		}
	}

	// Pass 2: per-agent config. Only runs if the registry row specifies
	// a configSrc (e.g. "claude" for Claude Code; empty for Codex today).
	if t.configSrc == "" {
		return
	}
	configSource := filepath.Join(agentsRoot, t.configSrc)
	// The embedded tree may not contain a configSrc dir even if the
	// registry promises one — defensive check for forward compatibility.
	if _, err := os.Stat(configSource); err != nil {
		return
	}
	configDest := filepath.Join(scopeRoot, t.configRel)
	if err := installAgentConfig(configSource, configDest); err != nil {
		fmt.Fprintf(os.Stderr, "    config: %v\n", err)
	}
}

// resolveScope picks the install scope from either an explicit --scope flag
// (the non-interactive path used by CI / scripted callers) or the interactive
// prompt. Validation of the flag value is delegated to parseScope so the
// flag and the all-flags branch of resolveInitConfig share one validator.
func resolveScope(flagValue string, in io.Reader) (initScope, error) {
	if flagValue == "" {
		return promptScope(in)
	}
	return parseScope(flagValue)
}

// parseScope is the standard string → initScope mapper. Used by both
// resolveScope (legacy flag path) and initFlags.toConfig (all-flags
// non-interactive path) so the accepted vocabulary lives in one place.
func parseScope(s string) (initScope, error) {
	switch s {
	case "project":
		return scopeProject, nil
	case "user":
		return scopeUser, nil
	default:
		return 0, fmt.Errorf("invalid --scope: %q (expected project or user)", s)
	}
}

// parseReviewPer is the standard validator for the review_per
// value, accepted by both --review-per and the line prompt. Returning
// the input unchanged on success keeps callers honest that the only thing
// the value passes through is the allowlist check.
func parseReviewPer(s string) (string, error) {
	switch s {
	case reviewPerTask, reviewPerPlan:
		return s, nil
	default:
		return "", fmt.Errorf("invalid --review-per: %q (expected %s or %s)",
			s, reviewPerTask, reviewPerPlan)
	}
}

// promptScope reads one line from `in` and parses it as a scope choice.
// Acceptable inputs are exactly "1" or "2" (trimmed); anything else is
// an error. Taking an io.Reader (rather than reading os.Stdin directly)
// keeps the function testable.
//
// Note: ReadString blocks until a newline, so an interactive caller who
// closes stdin without typing will hang. CI callers should pipe their
// choice (`echo 2 | x-x init`).
func promptScope(in io.Reader) (initScope, error) {
	fmt.Println("Where should agent skills be installed?")
	fmt.Println("  1) This project only")
	fmt.Println("  2) All my projects (user scope)")
	fmt.Print("Choose [1/2]: ")
	line, err := bufReader(in).ReadString('\n')
	// Only return the error if we got nothing at all. A common case is
	// EOF immediately after the choice digit (no trailing newline) —
	// ReadString returns the line AND io.EOF together; we want to honor
	// the choice in that case.
	if err != nil && line == "" {
		return 0, fmt.Errorf("read choice: %w", err)
	}
	switch strings.TrimSpace(line) {
	case "1":
		return scopeProject, nil
	case "2":
		return scopeUser, nil
	default:
		return 0, fmt.Errorf("invalid choice: %q (expected 1 or 2)", strings.TrimSpace(line))
	}
}

// resolveAgents picks which agent targets get the install. Flag wins when
// non-empty; otherwise the interactive multi-select runs against `in`.
//
// Selection ordering: the returned slice always preserves agentTargets
// order, regardless of the order the user typed keys or numbers, so the
// install loop's progress output stays deterministic.
func resolveAgents(flagValues []string, in io.Reader) ([]agentTarget, error) {
	if len(flagValues) == 0 {
		return promptAgents(in)
	}
	return resolveAgentsFromKeys(flagValues)
}

// resolveAgentsFromKeys is the non-interactive arm of resolveAgents: it
// maps a list of `key` strings (already comma-split by stringSliceFlag)
// back to the matching agentTarget rows. Unknown keys produce a single
// error listing both the offenders and the valid set.
func resolveAgentsFromKeys(keys []string) ([]agentTarget, error) {
	want := make(map[string]bool, len(keys))
	for _, k := range keys {
		k = strings.TrimSpace(k)
		if k != "" {
			want[k] = true
		}
	}
	if len(want) == 0 {
		return nil, fmt.Errorf("--agents: at least one agent required")
	}
	var picked []agentTarget
	for _, t := range agentTargets {
		if want[t.key] {
			picked = append(picked, t)
			delete(want, t.key)
		}
	}
	if len(want) > 0 {
		unknown := make([]string, 0, len(want))
		for k := range want {
			unknown = append(unknown, k)
		}
		sort.Strings(unknown)
		valid := make([]string, len(agentTargets))
		for i, t := range agentTargets {
			valid[i] = t.key
		}
		return nil, fmt.Errorf("--agents: unknown agent(s): %s (valid: %s)",
			strings.Join(unknown, ", "), strings.Join(valid, ", "))
	}
	return picked, nil
}

// promptAgents reads one line from `in` and parses it as a comma-separated
// list of 1-based agent numbers (matching the printed picker). Empty input
// — including EOF before any byte — defaults to "all agents", which keeps
// existing scripted callers that pipe nothing to `--scope` flows working
// after this prompt was inserted in front of them.
func promptAgents(in io.Reader) ([]agentTarget, error) {
	fmt.Println("Which agents should be installed?")
	for i, t := range agentTargets {
		fmt.Printf("  %d) %s\n", i+1, t.name)
	}
	fmt.Print("Choose by number, comma-separated (default all): ")
	line, err := bufReader(in).ReadString('\n')
	// EOF with no input → default to all. Same justification as promptScope's
	// "honor a trailing-newline-free choice", inverted: nothing typed at all
	// is a legitimate "I want defaults" signal in a multi-select.
	if err != nil && line == "" {
		return allAgents(), nil
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return allAgents(), nil
	}
	pickedIdx := make(map[int]bool)
	for _, tok := range strings.Split(line, ",") {
		tok = strings.TrimSpace(tok)
		n, err := strconv.Atoi(tok)
		if err != nil || n < 1 || n > len(agentTargets) {
			return nil, fmt.Errorf("invalid agent choice: %q (expected 1..%d, comma-separated)", tok, len(agentTargets))
		}
		pickedIdx[n] = true
	}
	// Walk agentTargets in registry order so the result mirrors the install
	// loop's emission order, not the order the user typed.
	picked := make([]agentTarget, 0, len(pickedIdx))
	for i, t := range agentTargets {
		if pickedIdx[i+1] {
			picked = append(picked, t)
		}
	}
	return picked, nil
}

// allAgents returns a fresh copy of every agentTarget. Returning a copy
// (not the global slice) prevents an upstream caller from mutating the
// registry by accident.
func allAgents() []agentTarget {
	out := make([]agentTarget, len(agentTargets))
	copy(out, agentTargets)
	return out
}

// promptPrefixWidth reads one line from `in` and parses it as the
// zero-padded plan-prefix width. Empty input (blank line / EOF before
// any byte) accepts the project default so headless callers that pipe
// the older two-prompt-only inputs continue to work after this prompt
// joined the sequence.
func promptPrefixWidth(in io.Reader) (int, error) {
	fmt.Println("Prefix width for plan files")
	fmt.Println("  Zero-padded width for plan filenames (e.g. width 4 → 0001-foo.md).")
	fmt.Println("  Higher = more headroom before plan numbers run out.")
	fmt.Printf("Choose [default %d]: ", defaultPrefixWidth)
	return readPositiveIntLine(in, defaultPrefixWidth, "prefix-width")
}

// promptMaxPlanLines reads one line from `in` and parses it as the plan
// line-count cap. Same default-on-empty semantics as promptPrefixWidth.
// The cap is what `x-x plans lint` enforces — tight values keep AI agents
// from sprawling, looser values let well-scoped plans breathe.
func promptMaxPlanLines(in io.Reader) (int, error) {
	fmt.Println("Maximum lines per plan")
	fmt.Println("  Keeps AI agents on a short leash:")
	fmt.Println("  forces them to split sprawling work into smaller, reviewable plans.")
	fmt.Printf("Choose [default %d]: ", defaultMaxPlanLines)
	return readPositiveIntLine(in, defaultMaxPlanLines, "max-plan-lines")
}

// promptReviewPer reads one line from `in` and parses it as the
// review cadence: "1" → task, "2" → plan. Empty input accepts the
// default (task), matching the empty-line-defaults convention used by
// the sibling prompts.
func promptReviewPer(in io.Reader) (string, error) {
	fmt.Println("Pause for review after every…")
	fmt.Printf("  1) %s — review each EARS criterion as the planner finishes it (default)\n", reviewPerTask)
	fmt.Printf("  2) %s — review only at plan boundaries (looser loop, larger diffs)\n", reviewPerPlan)
	fmt.Print("Choose [1/2, default 1]: ")
	line, err := bufReader(in).ReadString('\n')
	if err != nil && line == "" {
		return defaultReviewPer, nil
	}
	switch strings.TrimSpace(line) {
	case "", "1":
		return reviewPerTask, nil
	case "2":
		return reviewPerPlan, nil
	default:
		return "", fmt.Errorf("invalid review-per choice: %q (expected 1 or 2)", strings.TrimSpace(line))
	}
}

// readPositiveIntLine is the shared helper behind promptPrefixWidth and
// promptMaxPlanLines: read one line, trim, accept default on empty, parse
// as a positive int otherwise. `name` is included in the error message
// so the user can tell which prompt failed.
func readPositiveIntLine(in io.Reader, def int, name string) (int, error) {
	line, _ := bufReader(in).ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def, nil
	}
	n, err := strconv.Atoi(line)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid %s: %q (expected positive integer)", name, line)
	}
	return n, nil
}

// bufReader returns in unchanged if it's already a *bufio.Reader; otherwise
// it wraps it in a fresh one. Lets back-to-back prompts share a single
// buffered reader (so one's read-ahead doesn't swallow the next's input)
// while tests can still pass a plain strings.NewReader and have it work.
func bufReader(in io.Reader) *bufio.Reader {
	if br, ok := in.(*bufio.Reader); ok {
		return br
	}
	return bufio.NewReader(in)
}

// scopeRootFor resolves the chosen scope to its filesystem root:
//
//	scopeProject → the current working directory
//	scopeUser    → the user's home directory
//
// The default branch is a defensive guard — promptScope only ever produces
// one of the two valid values, but if a future caller forgets, we error.
func scopeRootFor(scope initScope, cwd string) (string, error) {
	switch scope {
	case scopeProject:
		return cwd, nil
	case scopeUser:
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return home, nil
	default:
		return "", fmt.Errorf("invalid scope: %d", scope)
	}
}

// listSkills returns the top-level subdirectory names under source. Each
// represents one skill bundle that init will install into every agent
// target. Dotfiles (and dot-prefixed dirs) are filtered out so things like
// a stray .DS_Store don't surface as "skills".
//
// Note: dirs whose name STARTS with "_" ARE included — by convention
// these are shared helpers consumed by other skills. None ship today,
// but keeping the filter permissive avoids a re-rule when one is added.
func listSkills(source string) ([]string, error) {
	entries, err := os.ReadDir(source)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", source, err)
	}
	var skills []string
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		skills = append(skills, e.Name())
	}
	return skills, nil
}

// installSkill installs one skill at one destination using the chosen
// strategy (symlink or copy). Re-runs always overwrite: skills are pure
// repo-shipped content, ownership of the destination is not tracked, and
// the `ownedSkills` allowlist already restricts `skill remove` so user-authored
// dirs with foreign names are never touched on the way out.
func installSkill(src, dest string, useSymlink bool) error {
	// Clean any prior install (or stray content) at dest. RemoveAll on a
	// missing path is a no-op so we don't need to stat first.
	if err := os.RemoveAll(dest); err != nil {
		return fmt.Errorf("remove existing %s: %w", dest, err)
	}
	if useSymlink {
		err := os.Symlink(src, dest)
		if err == nil {
			return nil
		}
		// Filesystems that don't support symlinks (some FAT32 mounts,
		// network shares with restrictive policies, etc.) surface
		// EOPNOTSUPP / EPERM. Fall through to the copy path so the
		// user still gets a working install.
		fmt.Fprintf(os.Stderr, "    %s: symlink failed (%v), falling back to copy\n", filepath.Base(dest), err)
	}
	return copyTree(src, dest)
}

// copyTree recursively copies src to dest using filepath.WalkDir. It
// creates directories with 0o700 perms and delegates file copies to
// copyFile. Used by installSkill on the copy path.
//
// Symlink note: filepath.WalkDir does NOT follow symlinks during the walk
// (unlike filepath.Walk's older behavior). Since our source is the
// always-materialized embed tree, this is fine — there are no symlinks
// inside it.
func copyTree(src, dest string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dest, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		return copyFile(path, target)
	})
}

// copyFile copies one regular file from src to dest. The named-return
// pattern lets the deferred Close on dest promote a flush error into the
// returned error, which matters because some filesystems only report
// write failures at close time, not during io.Copy.
func copyFile(src, dest string) (retErr error) {
	in, err := os.Open(src) // #nosec G304 -- src derived from agentsTarget.
	if err != nil {
		return err
	}
	// Source close errors are typically meaningless (we already read
	// everything we needed). Discard.
	defer func() { _ = in.Close() }()
	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return err
	}
	// O_TRUNC isn't strictly needed (installSkill RemoveAlls dest first
	// on the overwrite path) but is harmless and makes the call self-
	// contained if copyFile is ever used standalone.
	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600) // #nosec G304 -- dest under agent skill dir.
	if err != nil {
		return err
	}
	defer func() {
		// Promote close error if we don't already have a copy error.
		// This is the standard "Close-on-defer for writers" idiom.
		if cerr := out.Close(); retErr == nil {
			retErr = cerr
		}
	}()
	_, err = io.Copy(out, in)
	return err
}

// exitErr is the shared "log + exit 1" used by subcommand entry points
// (runInit, runSkillsRemove) when a precondition fails before per-item
// work begins. Pulled into a helper to keep the call sites uniform.
func exitErr(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

// notProjectBanner is the user-facing diagnostic shared by every project
// marker check. Deliberately does NOT name any of the on-disk files we check for:
// users only need to know the directory isn't initialized and that
// `x-x init` is the fix. Keeping the message uniform across every
// command means the failure mode is instantly recognizable.
const notProjectBanner = "error: not an x-x project — run `x-x init` to initialize the current directory first."

// projectAlreadyInitBanner is the diagnostic `x-x init` prints when the
// current directory already passes checkProject. Naming plansDir is OK
// here (unlike notProjectBanner) because the user is being told what to
// delete to retry — a path is the actionable answer, not a leak.
const projectAlreadyInitBanner = "error: x-x project already initialized in this directory.\n\nTip: delete `" + plansDir + "/_config.lock` and run `x-x skills remove --project` to re-init from scratch."

// checkProject reports whether the current working directory is an
// initialized x-x project. The contract is a single on-disk marker:
//
//	plansDir/plansConfigLockFile (the plan-tooling lock pin)
//
// Missing → not an initialized project. Other files under plansDir
// (the systems registry, plan files) are not required by the check.
// Keying solely on the lock file is what makes the documented "delete
// the lock file to re-init" flow work: the user can opt back into a
// fresh init without losing plans or the systems registry. The function
// deliberately returns a generic `not an x-x project` error rather than
// naming the missing file so the diagnostic stays uniform with the
// banner requireProject prints. Separated from requireProject so unit
// tests can exercise the check without exiting the process.
func checkProject() error {
	if _, err := os.Stat(filepath.Join(plansDir, plansConfigLockFile)); err != nil {
		return fmt.Errorf("not an x-x project")
	}
	return nil
}

// requireProject is the CLI check that every project-level subcommand
// (`plans *`, `skills remove --project`) calls before doing real work.
// When checkProject fails it prints the shared banner and exits 2 — the
// same code used for usage errors, since "wrong directory" is a usage
// mistake from the user's perspective.
//
// Called AFTER per-subcommand flag/positional-arg validation so a
// genuine usage error (bad flag, stray positional) still wins the
// diagnostic — the user gets the most actionable feedback first.
func requireProject() {
	if err := checkProject(); err != nil {
		fmt.Fprintln(os.Stderr, notProjectBanner)
		os.Exit(2)
	}
}
