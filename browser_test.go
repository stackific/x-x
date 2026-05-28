// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"slices"
	"strings"
	"testing"
)

// TestHasDesktopFor pins the per-GOOS desktop-detection contract that
// runDefault keys off when deciding whether to launch a browser. The pure
// form takes the inputs runtime would otherwise reach for, so every
// platform branch is exercised regardless of which OS the test binary
// runs on.
func TestHasDesktopFor(t *testing.T) {
	cases := []struct {
		name    string
		goos    string
		display string
		wayland string
		want    bool
	}{
		// macOS / Windows are always desktop-capable from x-x's point of
		// view — server-only edge cases (Windows Server Core, headless
		// macOS) are not the audience for an interactive bare-x-x run.
		{"darwin always true", "darwin", "", "", true},
		{"darwin ignores DISPLAY", "darwin", ":0", "", true},
		{"windows always true", "windows", "", "", true},
		// Linux: DISPLAY (X11) or WAYLAND_DISPLAY non-empty is the signal.
		{"linux with DISPLAY", "linux", ":0", "", true},
		{"linux with WAYLAND_DISPLAY", "linux", "", "wayland-0", true},
		{"linux with both", "linux", ":0", "wayland-0", true},
		{"linux headless", "linux", "", "", false},
		// Unsupported platforms refuse — the per-OS launcher branch in
		// browserCommandFor would also return an error for these.
		{"freebsd unsupported", "freebsd", ":0", "", false},
		{"plan9 unsupported", "plan9", "", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := hasDesktopFor(tc.goos, tc.display, tc.wayland); got != tc.want {
				t.Fatalf("hasDesktopFor(%q,%q,%q) = %v, want %v",
					tc.goos, tc.display, tc.wayland, got, tc.want)
			}
		})
	}
}

// TestBrowserCommandFor pins the launcher shape for each supported OS.
// The string args matter — `rundll32 url.dll,FileProtocolHandler <url>`
// is the documented Windows invocation, and substituting `start` would
// silently break URL handoff on systems where cmd.exe is not on PATH.
func TestBrowserCommandFor(t *testing.T) {
	const url = "https://example.test/"
	cases := []struct {
		goos     string
		wantName string
		wantArgs []string
		wantErr  bool
	}{
		{"darwin", "open", []string{"open", url}, false},
		{"windows", "rundll32", []string{"rundll32", "url.dll,FileProtocolHandler", url}, false},
		{"linux", "xdg-open", []string{"xdg-open", url}, false},
		{"freebsd", "", nil, true},
		{"plan9", "", nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.goos, func(t *testing.T) {
			checkBrowserCommand(t, tc.goos, url, tc.wantName, tc.wantArgs, tc.wantErr)
		})
	}
}

// checkBrowserCommand drives one row of TestBrowserCommandFor's table.
// Extracted from the inline subtest body so gocognit doesn't trip on
// the wantErr / wantName / wantArgs branch fan-out — the assertions
// themselves are unchanged.
func checkBrowserCommand(t *testing.T, goos, url, wantName string, wantArgs []string, wantErr bool) {
	t.Helper()
	cmd, err := browserCommandFor(goos, url)
	if wantErr {
		if err == nil {
			t.Fatalf("browserCommandFor(%q,...) err = nil, want non-nil", goos)
		}
		return
	}
	if err != nil {
		t.Fatalf("browserCommandFor(%q,...) err = %v, want nil", goos, err)
	}
	// exec.Cmd.Path may be resolved against PATH; the safer assertion
	// is on the basename of the executable.
	if !strings.HasSuffix(cmd.Path, wantName) {
		t.Fatalf("cmd.Path = %q, want suffix %q", cmd.Path, wantName)
	}
	if !slices.Equal(cmd.Args, wantArgs) {
		t.Fatalf("cmd.Args = %v, want %v", cmd.Args, wantArgs)
	}
}
