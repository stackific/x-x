// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
)

// Env-var names hasDesktopFor consults on Linux. Defined here (not in
// constants.go) because they parameterize the per-GOOS branch logic in
// this file and are not on-disk path components. defaultBrowserURL is
// the sibling constant for this code path and lives in constants.go.
const (
	envDisplay        = "DISPLAY"
	envWaylandDisplay = "WAYLAND_DISPLAY"
)

// hasDesktop reports whether the current process is running in a session
// that can plausibly launch a graphical browser. The pure form
// hasDesktopFor is the testable equivalent — it takes the inputs that
// runtime would otherwise reach for via runtime.GOOS / os.Getenv, so the
// per-platform branches can all be exercised from a single test binary.
func hasDesktop() bool {
	return hasDesktopFor(runtime.GOOS, os.Getenv(envDisplay), os.Getenv(envWaylandDisplay))
}

// hasDesktopFor is the pure, testable form. macOS and Windows desktop
// sessions are treated as desktop-capable unconditionally — the rare
// server-only configurations (Windows Server Core, headless macOS over
// SSH with no window server) are not the audience for an interactive
// `stax` invocation, and the OS-level launcher (`open` / `rundll32`) is
// always present even on those edge cases. On Linux the standard signal
// is a non-empty DISPLAY (X11) or WAYLAND_DISPLAY; both empty means
// headless (SSH, server, container) and we refuse to launch.
func hasDesktopFor(goos, display, wayland string) bool {
	switch goos {
	case "darwin", "windows":
		return true
	case "linux":
		return display != "" || wayland != ""
	default:
		return false
	}
}

// browserCommand returns the per-OS command that hands a URL off to the
// user's default browser. The returned *exec.Cmd is unstarted; callers
// run it. Returns an error on unsupported platforms.
func browserCommand(url string) (*exec.Cmd, error) {
	return browserCommandFor(runtime.GOOS, url)
}

// browserCommandFor is the pure, testable form of browserCommand.
//
//	darwin  → `open <url>` (built into macOS since forever).
//	windows → `rundll32 url.dll,FileProtocolHandler <url>` — the
//	          documented invocation for "open this URL with the
//	          registered default scheme handler", works on every
//	          supported Windows.
//	linux   → `xdg-open <url>` — the freedesktop.org standard; every
//	          mainstream desktop distro ships it via xdg-utils.
//
// The url is the only variable input. It is a package-internal value
// (the bare-stax landing URL or, in tests, a fixed example.test URL),
// never user-supplied — so the gosec G204 warning about "subprocess
// launched with variable" does not apply here.
func browserCommandFor(goos, url string) (*exec.Cmd, error) {
	switch goos {
	case "darwin":
		return exec.Command("open", url), nil // #nosec G204 -- url is package-internal, not user-supplied.
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url), nil // #nosec G204 -- url is package-internal, not user-supplied.
	case "linux":
		return exec.Command("xdg-open", url), nil // #nosec G204 -- url is package-internal, not user-supplied.
	default:
		return nil, fmt.Errorf("unsupported platform: %s", goos)
	}
}

// openBrowser hands the URL off to the OS-default browser via the
// per-platform launcher. cmd.Start is intentionally non-blocking — the
// launcher forks the browser process and returns immediately, which is
// the behavior the CLI wants (do not stall stax waiting for the user to
// close the browser). The launcher's own stdout/stderr are discarded:
// they are OS chatter the caller does not act on.
func openBrowser(url string) error {
	cmd, err := browserCommand(url)
	if err != nil {
		return err
	}
	cmd.Stdout = nil
	cmd.Stderr = nil
	return cmd.Start()
}
