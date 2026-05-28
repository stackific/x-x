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
		case "post-install":
			// `x-x post-install` — installer hook. INSTALL.sh / INSTALL.ps1
			// invoke it on their last step to materialize ~/.x-x/agents/
			// from the binary's embed. Modelled as a subcommand rather
			// than a flag so it never collides with the bare-invocation
			// browser-open path and so the install pipeline calls it by
			// the same surface every other subcommand uses.
			runPostInstall(os.Args[2:])
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

// runDefault is the "no subcommand" path. It owns three distinct user
// surfaces:
//
//	x-x --version     → print the notice block (the historical contract
//	                    that INSTALL.sh / INSTALL.ps1 parse via
//	                    `awk 'NR==1 { print $NF }'` to seed
//	                    ~/.x-x/.config.json — DO NOT remove without
//	                    coordinating an installer-script update).
//	x-x --no-browser  → user-facing opt-out for the bare-invocation
//	                    browser launch. Seeds ~/.x-x/agents/ on first
//	                    run, then exits silently. Useful in CI or any
//	                    scripted context where a browser pop is wrong.
//	x-x               → open https://google.com in the user's default
//	                    browser, unless hasDesktop() reports no
//	                    graphical session. Prints "Opening …" so the
//	                    invocation isn't silently invisible.
//
// The installer hook (`x-x post-install`) is a sibling SUBCOMMAND, not a
// runDefault branch — it lives in runPostInstall so the install pipeline
// calls a stable, name-conflict-free surface that can never accidentally
// trigger the browser path.
//
// `ensureBundledAgents` runs first on every branch so the embedded skill
// tree lands under ~/.x-x/agents/ on the very first invocation of a
// freshly-installed binary, regardless of which flag the caller passed.
// The 24h update check fires from main() before dispatch (not here), so
// the upgrade nudge appears identically across every branch.
func runDefault(args []string) {
	// A dedicated FlagSet (rather than the global flag.CommandLine) keeps
	// the default-command flags isolated from any future subcommand flags
	// that might happen to share a name.
	fs := flag.NewFlagSet("x-x", flag.ExitOnError)
	versionFlag := fs.Bool("version", false, "print version and exit")
	noBrowser := fs.Bool("no-browser", false, "do not open the default browser")
	// Setting printAbout as the FlagSet's Usage means `x-x -h` shows the
	// notice + usage block — one standard help output for the default
	// path. Bare `x-x` does NOT route through this anymore (it opens a
	// browser); -h is the explicit "show me everything" surface.
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

	// --version keeps the historical notice contract the installer
	// scripts depend on. Print it and exit before any of the new
	// branches can interfere.
	if *versionFlag {
		printNotice()
		return
	}

	// --no-browser is the user-facing opt-out: seed-and-exit silently.
	if *noBrowser {
		return
	}

	// Implicit no-op when there's no graphical session to receive the
	// browser handoff (headless Linux: DISPLAY + WAYLAND_DISPLAY both
	// empty). Tell the user why nothing happened so the silence doesn't
	// read as a hang, and point at --no-browser for callers that want to
	// suppress the diagnostic in scripted contexts.
	if !hasDesktop() {
		fmt.Fprintln(os.Stderr, "no desktop environment detected; not opening browser (pass --no-browser to silence)")
		return
	}

	// Desktop session: hand the URL off to the OS-default browser and
	// announce the action on stdout. Start failures (no `xdg-open`
	// installed, broken `rundll32`, etc.) surface as a stderr error and
	// a non-zero exit — better than silently doing nothing.
	const url = "https://google.com"
	if err := openBrowser(url); err != nil {
		fmt.Fprintln(os.Stderr, "error opening browser:", err)
		os.Exit(1)
	}
	fmt.Printf("Opening %s in your browser…\n", url)
}

// runPostInstall is the `x-x post-install` subcommand: the installer
// hook that materializes ~/.x-x/agents/ from the binary's embed and
// exits silently. INSTALL.sh and INSTALL.ps1 invoke it on their last
// step instead of bare `x-x` — bare invocation opens a browser, which
// would pop a window mid-install.
//
// Takes no flags and no positional arguments. The strict reject of any
// extra argv prevents the installer scripts from accidentally tunneling
// future flags through this hook and changing the contract silently.
func runPostInstall(args []string) {
	fs := flag.NewFlagSet("x-x post-install", flag.ExitOnError)
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: x-x post-install")
		fmt.Fprintln(os.Stderr, "  Installer hook: seed ~/.x-x/agents/ and exit silently.")
	}
	_ = fs.Parse(args)
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "x-x post-install: unexpected argument: %s\n", fs.Arg(0))
		os.Exit(2)
	}
	if err := ensureBundledAgents(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// printNotice is the version-and-license header shared by `x-x` (bare),
// `x-x --version`, and any future place that needs to identify the binary.
// It deliberately does NOT include the usage block — printAbout adds that
// for the bare-invocation path. The first line's last whitespace token is
// the version string; the POSIX/PowerShell installers parse it that way to
// seed ~/.x-x/.config.json, so don't change the line format without also
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
// default output stays terse. printAbout is set as the FlagSet.Usage
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
	fmt.Println("  x-x                            Open https://google.com in the default browser (no-op without a desktop)")
	fmt.Println("  x-x --no-browser               Same as bare x-x, but skip the browser launch")
	fmt.Println("  x-x post-install               Installer hook: seed ~/.x-x/agents/ and exit silently")
	fmt.Println("  x-x init                       Install bundled agent skills + seed .x-plans/ (wizard or flag-driven)")
	fmt.Println("  x-x skills remove --user       Uninstall bundled x-x skills from $HOME")
	fmt.Println("  x-x skills remove --project    Uninstall bundled x-x skills from the current directory")
	fmt.Println("  x-x plans next-prefix          Print the next unused zero-padded plan prefix")
	fmt.Println("  x-x plans list                 List plans with slug, status, and declared systems")
	fmt.Println("  x-x plans lint                 Validate every plan file against the project schema")
	fmt.Println("  x-x plans slugify \"<title>\"    Print the kebab-case slug for a plan title")
	fmt.Println("  x-x --version                  Print version")
}
