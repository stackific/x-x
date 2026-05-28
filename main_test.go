// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
)

// captureStdout swaps os.Stdout for a pipe, runs f, and returns what was
// written. Used to assert on the CLI's notice/about output without going
// through a subprocess.
func captureStdout(t *testing.T, f func()) string {
	t.Helper()
	orig := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	done := make(chan string)
	go func() {
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, r)
		done <- buf.String()
	}()
	f()
	_ = w.Close()
	os.Stdout = orig
	out := <-done
	_ = r.Close()
	return out
}

// TestPrintNotice_ShapeIsInstallerParsable pins the line-1 contract that
// scripts/INSTALL.sh relies on (`awk 'NR==1 { print $NF }'` must return
// the Version string). Any reshuffle of printNotice that moves the
// version off the first line or out of the last token must break this test.
func TestPrintNotice_ShapeIsInstallerParsable(t *testing.T) {
	out := captureStdout(t, printNotice)
	lines := strings.Split(out, "\n")
	if len(lines) == 0 || lines[0] == "" {
		t.Fatalf("empty notice output: %q", out)
	}
	// INSTALL.sh extracts the version with `awk 'NR==1 { print $NF }'`.
	// Whatever ends up as the last whitespace-separated token on line 1
	// is the contract — pin it to the Version variable.
	tokens := strings.Fields(lines[0])
	if len(tokens) == 0 {
		t.Fatalf("line 1 has no tokens: %q", lines[0])
	}
	if tokens[len(tokens)-1] != Version {
		t.Fatalf("line-1 last token = %q, want %q (installer parses this)",
			tokens[len(tokens)-1], Version)
	}
	for _, want := range []string{
		"Stax by Stackific",
		"Copyright 2026 Stackific Inc.",
		"SPDX-License-Identifier: Apache-2.0",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("notice missing %q in %q", want, out)
		}
	}
}

// TestPrintAbout_IncludesUsage guards the user-facing command catalog —
// every subcommand surface advertised in docs/public/reference.md must
// also appear in `stax -h` output, including the shared --cwd flag
// footer. Adding a new subcommand without listing it here will fail the
// test, prompting a usage-block update.
//
// The local-server HTTP routes (/api/stats, /api/systems) are
// deliberately NOT listed in `-h` output — they're an internal
// implementation detail behind bare-stax's web UI, not a user surface,
// so no assertion looks for them here either.
func TestPrintAbout_IncludesUsage(t *testing.T) {
	out := captureStdout(t, printAbout)
	for _, want := range []string{
		"Usage:",
		"--no-browser",
		"post-install",
		"stax init",
		"stax skills remove --user",
		"stax skills remove --project",
		"stax plans next-prefix",
		"stax plans list",
		"stax plans lint",
		"stax --version",
		// The shared --cwd flag is advertised in a single footer block
		// (one line, not per-subcommand) so the catalog stays scannable.
		"--cwd <path>",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("about missing %q in %q", want, out)
		}
	}
	// HTTP routes must NOT leak into the help text — pin the absence.
	for _, banned := range []string{apiStatsPath, apiSystemsPath, serverDisplayURL} {
		if strings.Contains(out, banned) {
			t.Fatalf("about exposes internal server detail %q in %q", banned, out)
		}
	}
}
