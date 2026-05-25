// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// main is the entry point and pure dispatcher. The CLI follows a "git-style"
// subcommand layout: the first positional argument that does NOT start with
// "-" is treated as a subcommand and routed to its dedicated runner. Anything
// else (no args, or a leading flag like `--version`) falls through to
// runDefault, which owns the about banner and the existing flag parsing.
//
// The leading-dash check is what lets `x-x --version` keep working without
// being misinterpreted as a subcommand named "--version".
func main() {
	// Opportunistic 24h update check fires for EVERY invocation —
	// bare, --version, and every subcommand. Centralizing it here (rather
	// than peppering each runner with its own call) makes the upsell
	// behavior uniform: the user sees the same upgrade nudge whether they
	// ran `x-x`, `x-x init`, `x-x plans lint`, or anything else. The
	// function is best-effort and silent on every failure mode — a missing
	// config, no network, rate-limited, etc. — so it never disrupts the
	// real command. We run it BEFORE dispatch so any "new version
	// available" line appears at the top of the output, before the
	// subcommand's own writes.
	maybeNotifyUpdate()

	if len(os.Args) >= 2 && !strings.HasPrefix(os.Args[1], "-") {
		switch os.Args[1] {
		case "init":
			// `x-x init` — interactive scope prompt, then install skills
			// into Claude Code + Codex CLI directories. Lives in init.go.
			runInit(os.Args[2:])
			return
		case "skills":
			// `x-x skills <subcmd>` — currently only `remove --user|--project`.
			// Lives in skill.go.
			runSkills(os.Args[2:])
			return
		case "plans":
			// `x-x plans <subcmd>` — plan-tooling commands (today: next-prefix).
			// Lives in plan.go.
			runPlans(os.Args[2:])
			return
		default:
			// Unknown bare subcommand. We deliberately do NOT fall through
			// to runDefault so a typo like `x-x ini` exits visibly rather
			// than printing the about banner and hiding the mistake.
			fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", os.Args[1])
			os.Exit(2)
		}
	}
	// No subcommand → bare `x-x` or `x-x --version`. runDefault handles
	// both via flag parsing.
	runDefault(os.Args[1:])
}

// runDefault is the "no subcommand" path. Bare `x-x` and `x-x --version`
// are treated as one and the same: both print the notice block and
// lazy-write the bundled agent tree on first run. The --version flag is
// still parsed (for backward compat with `x-x --version` invocations) but
// no longer changes behavior — keeping the two paths unified means
// there's exactly one entry-point surface to reason about. The 24h update
// check fires from main() before dispatch, not here, so the same upsell
// nudge appears regardless of which command the user ran.
//
// `ensureBundledAgents` runs before the banner print so the very first
// invocation of a freshly-installed binary writes ~/.x-x/agents/ from the
// embedded FS — no explicit setup step required. Subsequent refreshes are
// the responsibility of the 24h update check in maybeNotifyUpdate.
func runDefault(args []string) {
	// A dedicated FlagSet (rather than the global flag.CommandLine) keeps
	// the default-command flags isolated from any future subcommand flags
	// that might happen to share a name.
	fs := flag.NewFlagSet("x-x", flag.ExitOnError)
	// Parsed and discarded: `--version` has no behavioral difference from
	// the bare invocation anymore. Kept on the FlagSet so the flag is still
	// listed in `-h` output and existing scripts that pass it keep working.
	_ = fs.Bool("version", false, "print version and exit")
	// Wiring printAbout as the FlagSet's Usage means `x-x -h` shows the
	// same banner you'd see by running `x-x` with no args — one canonical
	// help output for the default path.
	fs.Usage = printAbout
	// ExitOnError + ignoring Parse's return is intentional: Parse calls
	// os.Exit on errors, so any non-nil return is unreachable.
	_ = fs.Parse(args)

	// Lazy first-run write of the bundled skill library. If ~/.x-x/agents
	// already exists this is a stat-only no-op; otherwise it writes the
	// in-binary embed.FS to disk. Failure here is fatal because the rest
	// of the CLI assumes the dir is present once any subcommand runs.
	if err := ensureBundledAgents(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}

	// Bare `x-x` (or `x-x --version`) prints the generic notice only —
	// no usage block. The usage block is reserved for `-h` / `--help`,
	// which fs.Usage still points at (printAbout) above. Keeping the
	// banner short means a user who runs `x-x` by accident isn't
	// confronted with a wall of subcommand documentation; if they want
	// it, `x-x -h` shows everything.
	printNotice()
}

// printNotice is the version-and-license header shared by `x-x` (bare),
// `x-x --version`, and any future place that needs to identify the binary.
// It deliberately does NOT include the usage block — printAbout adds that
// for the bare-invocation path. The first line's last whitespace token is
// the version string; the POSIX/PowerShell installers parse it that way to
// seed ~/.x-x/.config.json, so don't change the line shape without also
// updating scripts/INSTALL.sh and scripts/INSTALL.ps1.
func printNotice() {
	// Version banner — includes the vendor so the binary identifies itself
	// even in CI logs that show no surrounding context.
	fmt.Printf("x-x by Stackific, %s\n", Version)
	// productTagline already ends with "\n", so use Print (not Println) to
	// avoid a double newline and silence vet's "redundant newline" check.
	fmt.Print(productTagline)
	// Blank separator before the copyright pair.
	fmt.Println()
	// SPDX line is the machine-readable license identifier scanners look
	// for; the copyright above is what humans expect to see.
	fmt.Println("Copyright 2026 Stackific Inc.")
	fmt.Println("SPDX-License-Identifier: Apache-2.0 — see LICENSE for the full text.")
}

// printAbout is the `-h` / `--help` panel: the notice followed by the
// usage block. Bare `x-x` and `x-x --version` deliberately do NOT call
// this — they only print the generic notice via printNotice so the
// default output stays terse. printAbout is wired as the FlagSet.Usage
// callback so users who explicitly ask for help still see the full table.
func printAbout() {
	// Notice block (version + copyright + SPDX) — single source of truth
	// shared with the --version path.
	printNotice()
	// Blank line separates the notice from the usage table.
	fmt.Println()
	// Inline command reference. Kept in-binary (not deferred to docs/public)
	// because the about banner is often the first thing a user sees and
	// should be self-sufficient.
	fmt.Println("Usage:")
	fmt.Println("  x-x init                       Install bundled agent skills + seed .x-plans/ (wizard or flag-driven)")
	fmt.Println("  x-x skills remove --user       Uninstall bundled x-x skills from $HOME")
	fmt.Println("  x-x skills remove --project    Uninstall bundled x-x skills from the current directory")
	fmt.Println("  x-x plans next-prefix          Print the next unused zero-padded plan prefix")
	fmt.Println("  x-x plans list                 List plans with slug, status, and declared systems")
	fmt.Println("  x-x plans lint                 Validate every plan file against the project schema")
	fmt.Println("  x-x plans slugify \"<title>\"    Print the kebab-case slug for a plan title")
	fmt.Println("  x-x --version                  Print version")
}
