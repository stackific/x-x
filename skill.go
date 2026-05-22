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
)

// runSkill dispatches `x-x skill <subcommand>`. Kept minimal — the only
// subcommand today is `remove`, but the file layout (separate runSkill /
// runSkillRemove / helpers) leaves room for `list`, `info`, etc. without
// restructuring.
//
// Receives the post-"skill" args slice (e.g. `["remove", "--user"]`).
// Unknown or missing subcommands exit with code 2 and a usage hint, never
// fall through silently.
func runSkill(args []string) {
	if len(args) == 0 {
		// `x-x skill` with no subcommand is an error, not the same as
		// the bare-`x-x` banner — we want a typo to be loud, not friendly.
		printSkillUsage(os.Stderr)
		os.Exit(2)
	}
	switch args[0] {
	case "remove":
		// Pass the remaining args (after "remove") so runSkillRemove
		// sees just its own flags, not the full os.Args tail.
		runSkillRemove(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown skill subcommand: %s\n", args[0])
		printSkillUsage(os.Stderr)
		os.Exit(2)
	}
}

// printSkillUsage writes the `x-x skill` help text to the given writer.
// Taking an io.Writer (rather than always writing to os.Stderr) lets future
// callers redirect to stdout for `--help`-style invocations without code
// duplication. Today every caller passes os.Stderr.
func printSkillUsage(w io.Writer) {
	// Discards on Fprintln are deliberate: writes go to os.Stderr in practice
	// (where Write failures are unrecoverable anyway) and errcheck under our
	// lint config flags io.Writer-typed sinks if returns are ignored implicitly.
	_, _ = fmt.Fprintln(w, "Usage: x-x skill <subcommand>")
	_, _ = fmt.Fprintln(w, "  remove --user      Uninstall bundled x-x skills from $HOME")
	_, _ = fmt.Fprintln(w, "  remove --project   Uninstall bundled x-x skills from the current directory")
}

// runSkillRemove uninstalls every bundled-skill directory `x-x init` could
// have written at one scope. The list of names we own (and therefore are
// allowed to delete) lives in constants.go's ownedSkills — a strict
// allowlist match. We never inspect markers or symlink targets here; the
// name is the single source of truth.
//
// What is NOT removed, on purpose:
//   - Any folder whose name is not in ownedSkills (user-authored skills
//     sitting alongside ours).
//   - Per-agent config files written by init (e.g. ~/.claude/settings.json).
//     They may have been edited by the user; we never touch them. Manual
//     cleanup if desired — see ownedFiles in constants.go for the inventory.
//   - The .x-plan/ scaffold at project scope. It is user content from the
//     moment init writes it (think of `git init`'s .gitignore — once written,
//     it's yours).
//   - Parent directories (.claude/, .codex/). Only the skills/ subdirectory
//     under each is potentially emptied + removed, never its parent.
func runSkillRemove(args []string) {
	fs := flag.NewFlagSet("skill remove", flag.ExitOnError)
	userScope := fs.Bool("user", false, "remove skills installed at user scope ($HOME)")
	projectScope := fs.Bool("project", false, "remove skills installed at project scope (current directory)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: x-x skill remove (--user | --project)")
	}
	_ = fs.Parse(args)

	// Mirror init.go's two-choice model: exactly one scope, never both.
	// We require an explicit flag rather than defaulting to a scope so a
	// careless `x-x skill remove` can't surprise the user by wiping the
	// wrong set of files.
	switch {
	case *userScope && *projectScope:
		fmt.Fprintln(os.Stderr, "error: --user and --project are mutually exclusive")
		os.Exit(2)
	case !*userScope && !*projectScope:
		// Neither flag passed — print the usage and exit. The usage
		// callback explains which flag to pick.
		fs.Usage()
		os.Exit(2)
	}

	// Project scope is meaningful only inside an x-x project — gate
	// before any work. User scope is global, so it never needs the check.
	if *projectScope {
		requireProject()
	}

	scopeRoot, label, err := removeScopeRoot(*userScope)
	if err != nil {
		exitErr(err)
	}
	fmt.Printf("Removing bundled x-x skills from %s scope (%s)\n", label, scopeRoot)

	// Build the allowlist set once. ownedSkills is small (one entry per
	// bundled skill) so the cost is negligible; the map gives the per-entry
	// removal loop an O(1) check.
	owned := make(map[string]bool, len(ownedSkills))
	for _, name := range ownedSkills {
		owned[name] = true
	}

	// Aggregate counts across every agent target so the final summary line
	// is a single "Removed N, skipped M" — easier to skim in CI logs than
	// per-target totals.
	removed, skipped := 0, 0
	for _, t := range agentTargets {
		// Each agent's skills live at <scopeRoot>/<t.skillsRel> (e.g.
		// $HOME/.claude/skills). The per-agent helper handles missing
		// directories gracefully.
		r, s := removeOurSkillsIn(filepath.Join(scopeRoot, t.skillsRel), t.name, owned)
		removed += r
		skipped += s
	}

	fmt.Printf("\nRemoved %d skill(s), skipped %d failed.\n", removed, skipped)
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
// simply has no x-x install at this scope, which is not an error.
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
		// Allowlist check is the only gate. A folder named anything not
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
	// If the skills directory is now empty (e.g. only contained x-x dirs),
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
	// project where they originally did `x-x init`.
	cwd, err := os.Getwd()
	if err != nil {
		return "", "", err
	}
	return cwd, "project", nil
}

// removeIfEmpty deletes dir only when it has zero entries. Used by
// removeOurSkillsIn to tidy up empty parents after their last x-x-owned
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
