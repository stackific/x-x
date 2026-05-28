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
// The leading-dash check is what lets `stax --version` keep working without
// being misinterpreted as a subcommand named "--version".
func main() {
	// Opportunistic 24h update check fires for EVERY invocation —
	// bare, --version, and every subcommand. Centralizing it here (rather
	// than peppering each runner with its own call) makes the upsell
	// behavior uniform: the user sees the same upgrade nudge whether they
	// ran `stax`, `stax init`, `stax plans lint`, or anything else. The
	// function is best-effort and silent on every failure mode — a missing
	// config, no network, rate-limited, etc. — so it never disrupts the
	// real command. We run it BEFORE dispatch so any "new version
	// available" line appears at the top of the output, before the
	// subcommand's own writes.
	maybeNotifyUpdate()

	if len(os.Args) >= 2 && !strings.HasPrefix(os.Args[1], "-") {
		switch os.Args[1] {
		case "init":
			// `stax init` — interactive scope prompt, then install skills
			// into Claude Code + Codex CLI directories. Lives in init.go.
			runInit(os.Args[2:])
			return
		case "skills":
			// `stax skills <subcmd>` — currently only `remove --user|--project`.
			// Lives in skill.go.
			runSkills(os.Args[2:])
			return
		case "plans":
			// `stax plans <subcmd>` — plan-tooling commands (today: next-prefix).
			// Lives in plan.go.
			runPlans(os.Args[2:])
			return
		case "post-install":
			// `stax post-install` — installer hook. INSTALL.sh / INSTALL.ps1
			// invoke it on their last step to materialize ~/.stax/agents/
			// from the binary's embed. Modelled as a subcommand rather
			// than a flag so it never collides with the bare-invocation
			// server path (which blocks on the listener) and so the
			// install pipeline calls it by the same surface every other
			// subcommand uses.
			runPostInstall(os.Args[2:])
			return
		default:
			// Unknown bare subcommand. We deliberately do NOT fall through
			// to runDefault so a typo like `stax ini` exits visibly rather
			// than printing the about banner and hiding the mistake.
			fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", os.Args[1])
			os.Exit(2)
		}
	}
	// No subcommand → bare `stax` or `stax --version`. runDefault handles
	// both via flag parsing.
	runDefault(os.Args[1:])
}

// runDefault is the "no subcommand" path. It owns three distinct user
// surfaces:
//
//	stax --version     → print the notice block (the historical contract
//	                    that INSTALL.sh / INSTALL.ps1 parse via
//	                    `awk 'NR==1 { print $NF }'` to seed
//	                    ~/.stax/.config.json — DO NOT remove without
//	                    coordinating an installer-script update).
//	stax --no-browser  → start the local HTTP server but do NOT hand
//	                    the URL off to the OS-default browser. Useful
//	                    in CI / scripted contexts where popping a
//	                    window is wrong; the server still runs and is
//	                    reachable at http://127.0.0.1:7829.
//	stax               → start a loopback HTTP server on
//	                    127.0.0.1:7829 (see server.go for the routes),
//	                    print the URL on stdout, and hand it off to
//	                    the OS-default browser when hasDesktop()
//	                    reports a graphical session. Blocks until
//	                    SIGINT / SIGTERM.
//
// The installer hook (`stax post-install`) is a sibling SUBCOMMAND, not a
// runDefault branch — it lives in runPostInstall so the install pipeline
// calls a stable, name-conflict-free surface that can never accidentally
// trigger the server path.
//
// `ensureBundledAgents` runs first on every branch so the embedded skill
// tree lands under ~/.stax/agents/ on the very first invocation of a
// freshly-installed binary, regardless of which flag the caller passed.
// The 24h update check fires from main() before dispatch (not here), so
// the upgrade nudge appears identically across every branch.
func runDefault(args []string) {
	// A dedicated FlagSet (rather than the global flag.CommandLine) keeps
	// the default-command flags isolated from any future subcommand flags
	// that might happen to share a name.
	fs := flag.NewFlagSet("stax", flag.ExitOnError)
	versionFlag := fs.Bool("version", false, "print version and exit")
	noBrowser := fs.Bool("no-browser", false, "start the local server but do not open the default browser")
	// --cwd is the git `-C <path>` analog: when set, chdir to the given
	// directory before starting the server. handleAPISystems reads
	// .stax/_data_systems.yaml from cwd, so --cwd is the supported way
	// for scripted callers (Claude Code sessions, CI installers) to
	// point the server at a sibling project without an explicit cd.
	cwdFlag := fs.String("cwd", "", "change to this directory before running (like git -C)")
	// Setting printAbout as the FlagSet's Usage means `stax -h` shows the
	// notice + usage block — one standard help output for the default
	// path. Bare `stax` does NOT route through this anymore (it starts
	// the server); -h is the explicit "show me everything" surface.
	fs.Usage = printAbout
	// ExitOnError + ignoring Parse's return is intentional: Parse calls
	// os.Exit on errors, so any non-nil return is unreachable.
	_ = fs.Parse(args)

	// Honor --cwd before any further work so ensureBundledAgents, the
	// server's handleAPISystems reads of .stax/_data_systems.yaml, and
	// any future cwd-sensitive logic all observe the directory the
	// caller asked for.
	applyCwdOrExit(*cwdFlag)

	// Lazy first-run write of the bundled skill library. If ~/.stax/agents
	// already exists this is a stat-only no-op; otherwise it writes the
	// in-binary embed.FS to disk. Failure here is fatal because the rest
	// of the CLI assumes the dir is present once any subcommand runs.
	if err := ensureBundledAgents(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}

	// --version keeps the historical notice contract the installer
	// scripts depend on. Print it and exit before the server branch
	// fires (which would otherwise block on the listener).
	if *versionFlag {
		printNotice()
		return
	}

	// Default path: launch the loopback HTTP server, optionally open a
	// browser at it, and block until SIGINT / SIGTERM. runServer prints
	// the listening URL on stdout itself — no need for an extra
	// "Opening …" line here.
	if err := runServer(os.Stdout, os.Stderr, !*noBrowser); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// runPostInstall is the `stax post-install` subcommand: the installer
// hook that materializes ~/.stax/agents/ from the binary's embed and
// exits silently. INSTALL.sh and INSTALL.ps1 invoke it on their last
// step instead of bare `stax` — bare invocation opens a browser, which
// would pop a window mid-install.
//
// Takes no flags and no positional arguments. The strict reject of any
// extra argv prevents the installer scripts from accidentally tunneling
// future flags through this hook and changing the contract silently.
func runPostInstall(args []string) {
	fs := flag.NewFlagSet("stax post-install", flag.ExitOnError)
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: stax post-install")
		fmt.Fprintln(os.Stderr, "  Installer hook: seed ~/.stax/agents/ and exit silently.")
	}
	_ = fs.Parse(args)
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "stax post-install: unexpected argument: %s\n", fs.Arg(0))
		os.Exit(2)
	}
	if err := ensureBundledAgents(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// printNotice is the version-and-license header shared by `stax` (bare),
// `stax --version`, and any future place that needs to identify the binary.
// It deliberately does NOT include the usage block — printAbout adds that
// for the bare-invocation path. The first line's last whitespace token is
// the version string; the POSIX/PowerShell installers parse it that way to
// seed ~/.stax/.config.json, so don't change the line format without also
// updating scripts/INSTALL.sh and scripts/INSTALL.ps1.
func printNotice() {
	// Version banner — includes the vendor so the binary identifies itself
	// even in CI logs that show no surrounding context.
	fmt.Printf("Stax by Stackific, %s\n", Version)
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
// usage block. Bare `stax` and `stax --version` deliberately do NOT call
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
	fmt.Println("  stax                            Open the Stax web UI in the default browser")
	fmt.Println("  stax --no-browser               Same as bare stax, but do not auto-open the browser")
	fmt.Println("  stax post-install               Installer hook: seed ~/.stax/agents/ and exit silently")
	fmt.Println("  stax init                       Install bundled agent skills + seed .stax/ (wizard or flag-driven)")
	fmt.Println("  stax skills remove --user       Uninstall bundled stax skills from $HOME")
	fmt.Println("  stax skills remove --project    Uninstall bundled stax skills from the current directory")
	fmt.Println("  stax plans next-prefix          Print the next unused zero-padded plan prefix")
	fmt.Println("  stax plans list                 List plans with slug, status, and declared systems")
	fmt.Println("  stax plans lint                 Validate every plan file against the project schema")
	fmt.Println("  stax plans slugify \"<title>\"    Print the kebab-case slug for a plan title")
	fmt.Println("  stax --version                  Print version")
	fmt.Println()
	fmt.Println("Common flag (every subcommand above):")
	fmt.Println("  --cwd <path>                    Run as if invoked from <path> (like git -C); validates that the directory exists")
}
