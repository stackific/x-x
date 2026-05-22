// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// updateConfig mirrors the on-disk shape of ~/.x-x/.config.json. The
// installer writes this file with the freshly-installed version and the
// current epoch; the CLI reads and updates it from then on. The struct
// tags lock the JSON key names so future field additions can't accidentally
// rename existing keys.
//
// LastChecked is a Unix epoch (seconds) — chosen over time.Time so the
// shell-based installer can produce the same JSON with `date +%s` without
// having to deal with timezone offsets, RFC3339 formatting, etc.
type updateConfig struct {
	Version     string `json:"version"`
	LastChecked int64  `json:"last_checked"`
}

// lastCheckedTime converts the stored epoch back into a time.Time. Kept as
// a method (rather than inlining time.Unix at every call site) so callers
// read like English: `time.Since(c.lastCheckedTime())`.
func (c updateConfig) lastCheckedTime() time.Time {
	return time.Unix(c.LastChecked, 0)
}

// configPath returns the absolute path to ~/.x-x/.config.json. Centralized
// so installer and CLI agree, and so a future relocation only touches one
// function. Mirrors agentsTarget's shape.
func configPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		// Same rationale as agentsTarget: bubble the error up rather
		// than fall back to a guess. Callers treat any error here as
		// "no config available" and silently skip the update check.
		return "", err
	}
	return filepath.Join(home, xxHomeDir, xxConfigFile), nil
}

// loadUpdateConfig reads .config.json off disk. Any error (missing file,
// malformed JSON, IO failure) is propagated unchanged — the only caller is
// maybeNotifyUpdate which treats any error as "skip the check this run".
func loadUpdateConfig(path string) (updateConfig, error) {
	var c updateConfig
	// ReadFile is bounded by available memory; the file is a handful of
	// bytes so streaming would be overkill.
	body, err := os.ReadFile(path) // #nosec G304 -- path derived from os.UserHomeDir.
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(body, &c); err != nil {
		// Returning the zero-value config alongside the error means
		// callers don't accidentally use partial parse results.
		return c, err
	}
	return c, nil
}

// saveUpdateConfig writes the config back to disk after a check. We pretty-
// print (2-space indent) because a human may eyeball this file. The trailing
// newline mirrors the convention shell tooling expects from text files.
func saveUpdateConfig(path string, c updateConfig) error {
	body, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		// MarshalIndent can only fail on cyclic or unsupported types
		// — our struct is plain primitives, so this branch is effectively
		// unreachable in practice but kept for completeness.
		return err
	}
	body = append(body, '\n')
	// 0o600 is honored on POSIX; Windows ignores it and the file inherits
	// the parent's NTFS ACL (user-restrictive by default in the profile).
	return os.WriteFile(path, body, 0o600)
}

// maybeNotifyUpdate consults ~/.x-x/.config.json and — at most once per 24
// hours — asks GitHub for the latest release. If a newer tag is available
// it prints a prominent upgrade nudge to stderr.
//
// Every code path is best-effort: a missing config, a network failure, or
// a rate-limit response all silently no-op so the CLI's primary work is
// never disrupted by upgrade plumbing. The function returns no error and
// no value — observation only.
//
// The 24-hour cadence is enforced via last_checked, not a process-level
// rate-limiter, so even rapid back-to-back invocations only hit the API
// once per day.
func maybeNotifyUpdate() {
	path, err := configPath()
	if err != nil {
		// Couldn't even compute the path (no $HOME). Bail silently —
		// the binary is likely running in a stripped-down environment
		// where update nudges aren't useful anyway.
		return
	}
	c, err := loadUpdateConfig(path)
	if err != nil {
		// Missing config most commonly means the binary was built
		// locally (no installer was run). Treating this as "no check"
		// avoids false positives where a contributor sees an upsell
		// nudge for a version their dev binary doesn't compare to.
		return
	}
	if time.Since(c.lastCheckedTime()) < updateCheckInterval {
		// Checked recently. Skip the network round-trip.
		return
	}

	// 24h cadence reached → also rewrite $HOME/<xxHomeDir>/agents from the
	// binary's embed. This keeps the global skill library in lockstep with
	// whatever binary version is currently installed: if the user upgraded
	// since the last check, the new embed lands here. Scope is strictly
	// the global tree — project-level skills under .claude/, .agents/,
	// .codex/ are owned by `x-x init` and never touched here. Failure is
	// logged but never fatal; the update check is opportunistic.
	if err := writeBundledAgents(true); err != nil {
		fmt.Fprintf(os.Stderr, "warning: refresh global skills: %v\n", err)
	}

	latest, fetchErr := fetchLatestVersion()

	// Always bump last_checked so a flaky network doesn't make us re-probe
	// on every invocation. We deliberately update even on fetch errors
	// — the goal is to bound how often we hit GitHub, not to retry until
	// success.
	c.LastChecked = time.Now().Unix()
	// Save failures here are non-fatal — worst case is we re-probe the
	// next invocation. Logging or surfacing the error would be noise.
	_ = saveUpdateConfig(path, c)

	// Three "no nudge" conditions in one branch:
	//   1. fetchErr != nil — network/API problem; we already updated
	//      last_checked so we won't hammer on retries.
	//   2. latest == ""    — defensive: GitHub returned 200 but no tag
	//      (e.g. a draft release without tag_name).
	//   3. latest == c.Version — already on the latest tag.
	if fetchErr != nil || latest == "" || latest == c.Version {
		return
	}

	// Compose the upsell. All writes go to stderr so the CLI's stdout
	// (anything a user might pipe) stays clean. The blank-line padding
	// makes the block stand out from preceding command output.
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "=== UPDATE AVAILABLE ===")
	fmt.Fprintf(os.Stderr, "A new x-x version is available: %s (you have %s)\n", latest, c.Version)
	fmt.Fprintln(os.Stderr, "Strongly recommended: re-run the installer to update.")
	// Both install URLs are surfaced — the user picks the one matching
	// their shell. The URLs come from constants.go so they stay in lockstep
	// with whatever the docs and website point at.
	fmt.Fprintf(os.Stderr, "  sh:          curl -fsSL %s | sh\n", installShURL)
	fmt.Fprintf(os.Stderr, "  PowerShell:  irm %s | iex\n", installPS1URL)
	fmt.Fprintln(os.Stderr)
}

// fetchLatestVersion makes a single HTTP GET against the GitHub Releases
// API and returns the `tag_name` field of the response. The request is
// unauthenticated — the 60-req/hour limit per IP is plenty for a CLI that
// probes at most once a day.
//
// Errors are returned unmodified so the caller can decide policy (the
// caller silently no-ops on any error; see maybeNotifyUpdate).
func fetchLatestVersion() (string, error) {
	// Construct a fresh client with a short timeout. Reusing the global
	// http.DefaultClient would inherit its zero timeout (= no timeout),
	// which is a footgun on a slow network.
	client := &http.Client{Timeout: updateHTTPTimeout}
	resp, err := client.Get(releasesAPIURL) // #nosec G107 -- constant URL.
	if err != nil {
		// Network/DNS/timeout errors all land here. No retry — we'll
		// try again 24h from now per maybeNotifyUpdate's cadence.
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		// Non-200 typically means 404 (no releases yet — common during
		// initial development) or 403 (rate-limited). Both are recoverable
		// situations; we return a descriptive error and the caller skips.
		return "", fmt.Errorf("status %s", resp.Status)
	}
	// Inline anonymous struct: we only care about one field of the
	// (large) GitHub release payload, so don't bother modeling the rest.
	// The json package ignores any field not present in the struct.
	var payload struct {
		TagName string `json:"tag_name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		// Body wasn't JSON or didn't have the expected shape. Surface
		// as an error so the upsell stays silent.
		return "", err
	}
	return payload.TagName, nil
}
