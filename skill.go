// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
)

// runSkills dispatches `stax skills <subcommand>`. Kept minimal — the only
// subcommand today is `remove`, but the file layout (separate runSkills /
// runSkillsRemove / helpers) leaves room for `list`, `info`, etc. without
// restructuring.
//
// Receives the post-"skills" args slice (e.g. `["remove", "--user"]`).
// Unknown or missing subcommands exit with code 2 and a usage hint, never
// fall through silently.
func runSkills(args []string) {
	if len(args) == 0 {
		// `stax skills` with no subcommand is an error, not the same as
		// the bare-`stax` banner — we want a typo to be loud, not friendly.
		printSkillsUsage(os.Stderr)
		os.Exit(2)
	}
	switch args[0] {
	case "remove":
		// Pass the remaining args (after "remove") so runSkillsRemove
		// sees just its own flags, not the full os.Args tail.
		runSkillsRemove(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown skills subcommand: %s\n", args[0])
		printSkillsUsage(os.Stderr)
		os.Exit(2)
	}
}

// printSkillsUsage writes the `stax skills` help text to the given writer.
// Taking an io.Writer (rather than always writing to os.Stderr) lets future
// callers redirect to stdout for `--help`-style invocations without code
// duplication. Today every caller passes os.Stderr.
func printSkillsUsage(w io.Writer) {
	// Discards on Fprintln are deliberate: writes go to os.Stderr in practice
	// (where Write failures are unrecoverable anyway) and errcheck under our
	// lint config flags io.Writer-typed sinks if returns are ignored implicitly.
	_, _ = fmt.Fprintln(w, "Usage: stax skills <subcommand>")
	_, _ = fmt.Fprintln(w, "  remove --user      Uninstall bundled stax skills from $HOME")
	_, _ = fmt.Fprintln(w, "  remove --project   Uninstall bundled stax skills from the current directory")
}

// runSkillsRemove uninstalls every bundled-skill directory `stax init` could
// have written at one scope and subtracts the hook records `stax init`
// merged into per-agent JSON config files. Skill directories use the
// ownedSkills allowlist (strict name match); hook subtraction uses
// deep-equality against the currently bundled config files under
// ~/.stax/agents/<agent>/ — no markers, no install-time snapshots, no
// symlink-target inspection.
//
// What is NOT removed, on purpose:
//   - Any folder whose name is not in ownedSkills (user-authored skills
//     sitting alongside ours).
//   - The .stax/ scaffold at project scope. It is user content from the
//     moment init writes it (think of `git init`'s .gitignore — once written,
//     it's yours).
//   - Parent directories (.claude/, .codex/). Only the skills/ subdirectory
//     under each is potentially emptied + removed, never its parent.
//   - The per-agent JSON config files themselves (~/.claude/settings.json,
//     ~/.codex/hooks.json). Only the *records* we shipped inside their
//     configHooksKey subtree are subtracted; the file, top-level keys, and
//     any user-authored hook records stay. A user-tweaked variant of one of
//     our records (changed command, different matcher) survives the
//     deep-equality check and is preserved.
//   - Non-JSON per-agent config files (none today). They have no
//     subtraction path, so they are not consulted at all.
func runSkillsRemove(args []string) {
	flags := flag.NewFlagSet("skills remove", flag.ExitOnError)
	userScope := flags.Bool("user", false, "remove skills installed at user scope ($HOME)")
	projectScope := flags.Bool("project", false, "remove skills installed at project scope (current directory)")
	flags.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: stax skills remove (--user | --project)")
	}
	_ = flags.Parse(args)

	// Mirror init.go's two-choice model: exactly one scope, never both.
	// We require an explicit flag rather than defaulting to a scope so a
	// careless `stax skills remove` can't surprise the user by wiping the
	// wrong set of files.
	switch {
	case *userScope && *projectScope:
		fmt.Fprintln(os.Stderr, "error: --user and --project are mutually exclusive")
		os.Exit(2)
	case !*userScope && !*projectScope:
		// Neither flag passed — print the usage and exit. The usage
		// callback explains which flag to pick.
		flags.Usage()
		os.Exit(2)
	}

	// Project scope is meaningful only inside a stax project — check
	// before any work. User scope is global, so it never needs the check.
	if *projectScope {
		requireProject()
	}

	scopeRoot, label, err := removeScopeRoot(*userScope)
	if err != nil {
		exitErr(err)
	}
	fmt.Printf("Removing bundled stax skills from %s scope (%s)\n", label, scopeRoot)

	// Build the allowlist set once. ownedSkills is small (one entry per
	// bundled skill) so the cost is negligible; the map gives the per-entry
	// removal loop an O(1) check.
	owned := make(map[string]bool, len(ownedSkills))
	for _, name := range ownedSkills {
		owned[name] = true
	}

	// Aggregate counts across every agent target so the final summary line
	// is a single "Removed N, unmerged M, skipped P" — easier to skim in CI
	// logs than per-target totals.
	removed, unmerged, skipped := 0, 0, 0
	// Bundle root is needed for the hook un-merge; resolution failure here
	// is non-fatal and degrades the hook pass to a no-op while the skill
	// pass still runs.
	agentsRoot, agentsErr := agentsTarget()
	if agentsErr != nil {
		fmt.Fprintf(os.Stderr, "warning: %v (skipping hook un-merge)\n", agentsErr)
	}
	// Match init's encoding: scope is initScope here so t.skillsRelFor picks
	// the right path for agents whose project- and user-scope skill paths
	// differ (e.g. Copilot CLI).
	removeScope := scopeProject
	if *userScope {
		removeScope = scopeUser
	}
	for _, t := range agentTargets {
		// Each agent's skills live at <scopeRoot>/<t.skillsRelFor(scope)> (e.g.
		// $HOME/.claude/skills). The per-agent helper handles missing
		// directories gracefully.
		r, s := removeOurSkillsIn(filepath.Join(scopeRoot, t.skillsRelFor(removeScope)), t.name, owned)
		removed += r
		skipped += s
		// Hook un-merge: walk the bundled per-agent config dir and
		// subtract our shipped hook records from the user's counterpart
		// under <scopeRoot>/<t.configRel>. Agents that ship no config
		// (empty configSrc) are skipped — same check installAgentConfig uses.
		if agentsErr != nil || t.configSrc == "" {
			continue
		}
		m, hs := removeBundledHooksIn(
			filepath.Join(agentsRoot, t.configSrc),
			filepath.Join(scopeRoot, t.configRel),
			t.name,
		)
		unmerged += m
		skipped += hs
	}

	fmt.Printf("\nRemoved %d skill(s), unmerged %d config file(s), skipped %d failed.\n",
		removed, unmerged, skipped)

	// Anonymous-usage ping. Fires at the end of the happy path; the
	// exitErr/os.Exit paths above intentionally skip it for the same
	// reason runInit does (a fatal-error path that lost the event is
	// an acceptable trade for not wrapping every os.Exit call site).
	scopeLabel := "project"
	if *userScope {
		scopeLabel = "user"
	}
	track("skills_remove", telemetryEvent{
		"scope":               scopeLabel,
		"agent_count":         strconv.Itoa(len(agentTargets)),
		"skill_count_removed": strconv.Itoa(removed),
		"hook_count_unmerged": strconv.Itoa(unmerged),
	})
	flushTelemetry()
}

// removeOurSkillsIn walks one agent's skills directory and removes every
// entry whose name appears in constants.go's ownedSkills allowlist. Anything
// not on the allowlist — including user-authored skill folders that happen
// to share the same parent — is left strictly alone.
//
// We never inspect symlink targets here either — the name match is the
// single source of truth, so a manually-tweaked install still gets cleaned
// up cleanly.
//
// Returns (removed, skipped) so the caller can aggregate counts across all
// agent targets. Skips silently when the directory is absent — the agent
// simply has no stax install at this scope, which is not an error.
func removeOurSkillsIn(skillsDir, agentName string, owned map[string]bool) (removed, skipped int) {
	entries, err := os.ReadDir(skillsDir)
	if err != nil {
		// ErrNotExist is expected and silent (agent never had a skills
		// dir at this scope). Any other error gets surfaced so e.g. a
		// permissions issue is visible.
		if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(os.Stderr, "  %s: %v\n", skillsDir, err)
		}
		return 0, 0
	}
	fmt.Printf("  %-13s %s\n", agentName, skillsDir)
	for _, e := range entries {
		// Allowlist check is the only filter. A folder named anything not
		// in ownedSkills is implicitly user-authored and skipped silently
		// (we only log when *we own the name* and choose to act on it).
		if !owned[e.Name()] {
			continue
		}
		dest := filepath.Join(skillsDir, e.Name())
		// RemoveAll handles both the symlink case (just unlinks, never
		// follows) and the copied-dir case (recursive delete).
		if err := os.RemoveAll(dest); err != nil {
			fmt.Fprintf(os.Stderr, "    %s: %v\n", e.Name(), err)
			skipped++
			continue
		}
		fmt.Printf("    removed %s\n", e.Name())
		removed++
	}
	// If the skills directory is now empty (e.g. only contained stax dirs),
	// remove it too. Leave parent (.claude / .codex) alone — those host
	// user config files we never want to touch.
	_ = removeIfEmpty(skillsDir)
	return removed, skipped
}

// removeScopeRoot resolves the directory to scan for managed skills.
// Returns (root, label, err) — label is "user" or "project", used purely
// for the operator log line. Named returns make the call site readable:
// `scopeRoot, label, err := removeScopeRoot(...)`.
func removeScopeRoot(userScope bool) (root, label string, err error) {
	if userScope {
		// User scope = wherever os.UserHomeDir resolves (~ on POSIX,
		// %USERPROFILE% on Windows). Same as init.go's user-scope choice.
		home, err := os.UserHomeDir()
		if err != nil {
			return "", "", err
		}
		return home, "user", nil
	}
	// Project scope = current working directory. Same as init.go's
	// project-scope choice; the user is expected to run this from the
	// project where they originally did `stax init`.
	cwd, err := os.Getwd()
	if err != nil {
		return "", "", err
	}
	return cwd, "project", nil
}

// removeIfEmpty deletes dir only when it has zero entries. Used by
// removeOurSkillsIn to tidy up empty parents after their last stax-owned
// child is removed. Errors are returned but currently ignored by the caller
// — failure here is purely cosmetic (an empty dir left behind).
func removeIfEmpty(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	if len(entries) > 0 {
		// Anything left = either user content or a hidden file (.DS_Store
		// on macOS, Thumbs.db on Windows). Either way, leave it alone.
		return nil
	}
	return os.Remove(dir)
}
