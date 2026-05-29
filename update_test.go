// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestConfigPath confirms configPath composes $HOME + staxDir +
// staxConfigFile — the three constants are the contract; any inline
// fragment that bypasses them would silently break test isolation.
func TestConfigPath(t *testing.T) {
	home := pinHome(t)
	got, err := configPath()
	if err != nil {
		t.Fatalf("configPath: %v", err)
	}
	want := filepath.Join(home, staxDir, staxConfigFile)
	if got != want {
		t.Fatalf("configPath = %q, want %q", got, want)
	}
}

// TestUpdateConfig_LastCheckedTime pins the int64-epoch ↔ time.Time
// conversion: maybeNotifyUpdate uses the difference between this and
// time.Now() to decide whether to skip the network probe, so a unit
// drift here would silently disable the throttle.
func TestUpdateConfig_LastCheckedTime(t *testing.T) {
	c := updateConfig{LastChecked: 1700000000}
	got := c.lastCheckedTime()
	want := time.Unix(1700000000, 0)
	if !got.Equal(want) {
		t.Fatalf("lastCheckedTime = %v, want %v", got, want)
	}
}

// TestSaveLoadUpdateConfig_RoundTrip locks the protocol format: 2-space
// indent + trailing newline. The installer scripts (INSTALL.sh /
// INSTALL.ps1) sometimes diff this file by hand; a JSON layout change
// would surprise them.
func TestSaveLoadUpdateConfig_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "config.json")
	in := updateConfig{Version: "v9.9.9", LastChecked: 1700000000}
	if err := saveUpdateConfig(p, in); err != nil {
		t.Fatalf("saveUpdateConfig: %v", err)
	}
	body, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !strings.HasSuffix(string(body), "\n") {
		t.Fatalf("expected trailing newline, got: %q", body)
	}
	if !strings.Contains(string(body), "\n  \"version\"") {
		t.Fatalf("expected 2-space indent, got: %q", body)
	}
	out, err := loadUpdateConfig(p)
	if err != nil {
		t.Fatalf("loadUpdateConfig: %v", err)
	}
	if out != in {
		t.Fatalf("round-trip mismatch: got %+v, want %+v", out, in)
	}
}

// TestLoadUpdateConfig_Missing asserts the absent-file error path —
// callers (maybeNotifyUpdate) branch on this to silently skip the
// update check, so it must remain a real error, not a nil-with-zero-value.
func TestLoadUpdateConfig_Missing(t *testing.T) {
	_, err := loadUpdateConfig(filepath.Join(t.TempDir(), "absent.json"))
	if err == nil {
		t.Fatal("expected error for missing config")
	}
}

// TestLoadUpdateConfig_Malformed covers the "file present but garbage"
// case — must error rather than parse to zero-value, because zero LastChecked
// would make maybeNotifyUpdate falsely think the throttle window has expired.
func TestLoadUpdateConfig_Malformed(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "bad.json")
	if err := os.WriteFile(p, []byte("{not json"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := loadUpdateConfig(p); err == nil {
		t.Fatal("expected error for malformed config")
	}
}

// TestMaybeNotifyUpdate_SilentWhenConfigMissing pins the "no config →
// no-op" contract. Crucially, a missing config must NOT cause the
// function to create one, because that would imply a probe was made
// (and there should be no network IO in this code path).
func TestMaybeNotifyUpdate_SilentWhenConfigMissing(t *testing.T) {
	pinHome(t)
	// configPath resolves under HOME (no file there) — function must
	// silently no-op. We assert by simply not panicking and by leaving
	// no config file behind.
	maybeNotifyUpdate()
	p, _ := configPath()
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("config should not be created when missing initially, err=%v", err)
	}
}

// TestMaybeNotifyUpdate_SkipsWhenRecent verifies the throttle: with a
// fresh LastChecked, the function must NOT probe GitHub (we assert by
// checking LastChecked is unchanged after the call). This is the
// rate-limit guard for the unauthenticated API.
func TestMaybeNotifyUpdate_SkipsWhenRecent(t *testing.T) {
	home := pinHome(t)
	// Seed a fresh config to short-circuit the network round-trip.
	if err := os.MkdirAll(filepath.Join(home, staxDir), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	p, _ := configPath()
	in := updateConfig{Version: "v0.0.0", LastChecked: time.Now().Unix()}
	if err := saveUpdateConfig(p, in); err != nil {
		t.Fatalf("seed config: %v", err)
	}
	maybeNotifyUpdate()
	out, err := loadUpdateConfig(p)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	// Recent → no network probe → last_checked is left unchanged.
	if out.LastChecked != in.LastChecked {
		t.Fatalf("last_checked should not be touched on recent check: got %d want %d",
			out.LastChecked, in.LastChecked)
	}
}

// TestMaybeNotifyUpdate_NoTelemetry pins the disabled-telemetry contract
// for `maybeNotifyUpdate`. Both `update_check` and `update_apply` are
// commented out (only install / uninstall / lint events stay wired), so
// neither the throttle-skip path nor the post-throttle refresh path
// must fire telemetry. Exercises both paths in one test by seeding an
// expired config — maybeNotifyUpdate will attempt the GitHub round-trip
// (which may succeed or fail depending on CI network state), and either
// way no probe hits should land.
func TestMaybeNotifyUpdate_NoTelemetry(t *testing.T) {
	probe := newTelemetryProbe(t)
	pointTelemetryAt(t, probe.server.URL)

	home := pinHome(t)
	if err := os.MkdirAll(filepath.Join(home, staxDir), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	p, _ := configPath()
	// LastChecked far in the past forces the post-throttle path so the
	// disabled `update_apply` + `update_check` blocks are exercised.
	in := updateConfig{Version: "v0.0.0", LastChecked: time.Now().Add(-48 * time.Hour).Unix()}
	if err := saveUpdateConfig(p, in); err != nil {
		t.Fatalf("seed config: %v", err)
	}

	maybeNotifyUpdate()
	flushTelemetry()

	probe.mu.Lock()
	defer probe.mu.Unlock()
	if len(probe.hits) != 0 {
		t.Fatalf("maybeNotifyUpdate must not fire telemetry, got %d hits: %+v",
			len(probe.hits), probe.hits)
	}
}
