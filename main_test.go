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
		"x-x by Stackific",
		"Copyright 2026 Stackific Inc.",
		"SPDX-License-Identifier: Apache-2.0",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("notice missing %q in %q", want, out)
		}
	}
}

// TestPrintAbout_IncludesUsage guards the user-facing command catalog —
// every subcommand surface advertised in docs/public/reference.md must also
// appear in `x-x -h` output. Adding a new subcommand without listing it
// here will fail the test, prompting a usage-block update.
func TestPrintAbout_IncludesUsage(t *testing.T) {
	out := captureStdout(t, printAbout)
	for _, want := range []string{
		"Usage:",
		// Bare x-x opens https://google.com — the URL itself must appear
		// so a user reading `x-x -h` sees what will happen, not just
		// "open a browser".
		"https://google.com",
		"--no-browser",
		"post-install",
		"x-x init",
		"x-x skills remove --user",
		"x-x skills remove --project",
		"x-x plans next-prefix",
		"x-x plans list",
		"x-x plans lint",
		"x-x --version",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("about missing %q in %q", want, out)
		}
	}
}
