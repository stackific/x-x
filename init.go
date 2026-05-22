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
//  6. Drop the .x-plan/ scaffold (idempotent — only writes missing files).
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
	flags.Var(&agentsFlag, "agents", "comma-separated agent keys (e.g. claude,codex) — skip the interactive picker")
	// --scope makes the interactive prompt skippable for CI / scripted use.
	// Accepts "project" or "user"; any other value is rejected explicitly.
	// Leave blank to fall back to the interactive flow.
	scopeFlag := flags.String("scope", "", "project|user — skip the interactive prompt")
	flags.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: x-x init [--agents claude,codex] [--scope project|user]")
		fmt.Fprintln(os.Stderr, "  Installs the bundled agent skill library for Claude Code and Codex CLI.")
	}
	_ = flags.Parse(args)

	cwd, err := os.Getwd()
	if err != nil {
		// os.Getwd can fail in obscure cases (deleted cwd, permissions).
		// We can't do anything useful without it — bail.
		exitErr(err)
	}
	fmt.Printf("Setting up x-x in %s\n\n", cwd)

	// One buffered reader shared by every prompt that may run this turn.
	// Wrapping os.Stdin inside each prompt function would let the first
	// prompt's read-ahead buffer eat bytes the next prompt still needs.
	stdinR := bufio.NewReader(os.Stdin)

	// Resolve agents FIRST so the user picks WHAT before WHERE. Keeping
	// the question order stable ("which agents → which scope") matches
	// the order the install loop consumes them in.
	selectedAgents, err := resolveAgents(agentsFlag, stdinR)
	if err != nil {
		exitErr(err)
	}

	// Resolve scope: --scope wins if set, otherwise prompt. Keeping these
	// two branches inside resolveScope makes the runInit body smaller and
	// gives us one place to extend (e.g. honoring $X_X_SCOPE) later.
	scope, err := resolveScope(*scopeFlag, stdinR)
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

	scopeRoot, err := scopeRootFor(scope, cwd)
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
	useSymlink := scope == scopeUser && runtime.GOOS != "windows"
	strategy := "copy"
	if useSymlink {
		strategy = "symlink"
	}
	fmt.Printf("Installing %d skill(s) for %d agent(s) (%s)...\n", len(skills), len(selectedAgents), strategy)

	// Walk the selected subset of the registry. Agents not chosen at the
	// picker (or omitted from --agents) are silently skipped — their
	// install dirs are left untouched.
	for i := range selectedAgents {
		installForTarget(&selectedAgents[i], skills, scopeRoot, skillsSource, agentsRoot, useSymlink)
	}

	// .x-plan/ scaffold is written after skills so it's the last thing the
	// user sees. Failures here are non-fatal — they downgrade to a warning
	// because the skill install (the primary purpose) already succeeded.
	if err := writePlanScaffold(cwd); err != nil {
		fmt.Fprintf(os.Stderr, "warning: %v\n", err)
	}

	fmt.Println("\nDone.")
	// Plan files are first-class repo content (frontmatter + EARS tasks),
	// not local state. Nudge the user to commit them so the team shares the
	// same plan history. Phrased as a tip rather than auto-editing
	// .gitignore so we never touch git config behind the user's back.
	fmt.Printf("\nTip: commit %s/ to git so your team shares plan history.\n", planDir)
}

// writePlanScaffold creates the project-local .x-plan/ directory and seeds
// the two files that the plan tooling expects to find on disk:
//
//	_data_systems.yaml — empty placeholder; populated by the user as systems are added
//	_config.lock  — pinned plan-tooling defaults (prefix_width, etc.)
//
// Both files are only written when ABSENT so existing content survives
// re-runs. _config.lock specifically acts as a pin: re-running init
// never refreshes it, matching the conventional lock-file semantics
// (Cargo.lock, package-lock.json, etc.).
func writePlanScaffold(cwd string) error {
	dir := filepath.Join(cwd, planDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create %s: %w", dir, err)
	}
	// Empty placeholder — the plan tooling populates this as the project
	// grows. Writing nil content creates a zero-byte file.
	if err := writeIfAbsent(filepath.Join(dir, planSystemsFile), nil); err != nil {
		return err
	}
	// Inline anonymous struct: the lock file is JSON-shaped, but the only
	// place we materialize it is here, so a dedicated type would be overkill.
	lock := struct {
		PrefixWidth   int    `json:"prefix_width"`
		MaxPlanLines  int    `json:"max_plan_lines"`
		PlanReviewPer string `json:"plan_review_per"`
	}{
		PrefixWidth:   defaultPrefixWidth,
		MaxPlanLines:  defaultMaxPlanLines,
		PlanReviewPer: defaultPlanReviewPer,
	}
	body, err := json.MarshalIndent(lock, "", "  ")
	if err != nil {
		return err
	}
	// Append a trailing newline so the file matches standard text-file
	// conventions (every line ends with \n).
	body = append(body, '\n')
	return writeIfAbsent(filepath.Join(dir, planConfigLockFile), body)
}

// writeIfAbsent is the "create only if missing" primitive. Stat first;
// if the file exists, return nil and leave it alone. If it doesn't,
// write the given content with 0o600 perms. Used by writePlanScaffold.
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
func installForTarget(t *agentTarget, skills []string, scopeRoot, skillsSource, agentsRoot string, useSymlink bool) {
	// Pass 1: skills. Each skill lives at <scopeRoot>/<skillsRel>/<skill>/.
	skillsDir := filepath.Join(scopeRoot, t.skillsRel)
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
	if err := installAgentConfig(configSource, configDest, useSymlink); err != nil {
		fmt.Fprintf(os.Stderr, "    config: %v\n", err)
	}
}

// resolveScope picks the install scope from either an explicit --scope flag
// (the non-interactive path used by CI / scripted callers) or the interactive
// prompt. Validation of the flag value is done here so the prompt path stays
// untouched.
func resolveScope(flagValue string, in io.Reader) (initScope, error) {
	switch flagValue {
	case "":
		return promptScope(in)
	case "project":
		return scopeProject, nil
	case "user":
		return scopeUser, nil
	default:
		return 0, fmt.Errorf("invalid --scope: %q (expected project or user)", flagValue)
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
// Note: dirs whose name STARTS with "_" (e.g. _x-x_shared) ARE included
// — by convention these are shared helpers consumed by other skills. We
// install them too because their absence would break the dependent skills.
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
// the `ownedSkills` allowlist already gates `skill remove` so user-authored
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

// installAgentConfig walks src (e.g. ~/.x-x/agents/claude/) and installs
// each file under dest (e.g. ~/.claude/) preserving the relative path.
// Files that already exist at the destination are left alone so user
// customizations aren't trampled — this is the explicit divergence from
// skills, where x-x-owned dirs are overwritten on re-run.
//
// Rationale: config files (settings.json etc.) are often hand-edited
// by users. There's no marker pattern that works for individual files,
// so the conservative default is "don't touch if present". To refresh
// a config file, the user manually deletes it and re-runs init.
func installAgentConfig(src, dest string, useSymlink bool) error {
	if err := os.MkdirAll(dest, 0o700); err != nil {
		return err
	}
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			// Walk visits dirs but we only act on files — the MkdirAll
			// below covers any nested directories that need to be created.
			return nil
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dest, rel)
		// "Skip if exists" — see function comment for why.
		if _, err := os.Lstat(target); err == nil {
			fmt.Fprintf(os.Stderr, "    config %s: exists, skipping\n", rel)
			return nil
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return err
		}
		if useSymlink {
			return os.Symlink(path, target) // #nosec G122 -- walking ~/.x-x/agents/, which we materialize ourselves with no foreign symlinks.
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
		// This is the canonical "Close-on-defer for writers" idiom.
		if cerr := out.Close(); retErr == nil {
			retErr = cerr
		}
	}()
	_, err = io.Copy(out, in)
	return err
}

// exitErr is the shared "log + exit 1" used by subcommand entry points
// (runInit, runSkillRemove) when a precondition fails before per-item
// work begins. Pulled into a helper to keep the call sites uniform.
func exitErr(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

// checkProject reports whether the current working directory looks like
// an x-x project — concretely, whether planDir (.x-plan/) exists as a
// directory beneath cwd. Returns nil when it does, an explanatory error
// otherwise. Separated from requireProject so unit tests can exercise
// the check without exiting the process.
func checkProject() error {
	info, err := os.Stat(planDir)
	if err == nil && info.IsDir() {
		return nil
	}
	cwd, _ := os.Getwd()
	return fmt.Errorf("not an x-x project: no %s/ in %s", planDir, cwd)
}

// requireProject is the CLI gate that every project-level subcommand
// (`plan *`, `skill remove --project`) calls before doing real work.
// When checkProject fails it prints a polite two-line diagnostic and
// exits 2 — the same code used for usage errors, since "wrong directory"
// is a usage mistake from the user's perspective.
//
// Called AFTER per-subcommand flag/positional-arg validation so a
// genuine usage error (bad flag, stray positional) still wins the
// diagnostic — the user gets the most actionable feedback first.
func requireProject() {
	if err := checkProject(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		fmt.Fprintln(os.Stderr, "run `x-x init` to initialize the current directory as an x-x project.")
		os.Exit(2)
	}
}
