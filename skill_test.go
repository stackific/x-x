// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPrintSkillUsage guards the `x-x skill` help surface — the two
// remove flags must both appear, so adding a third without updating the
// help block fails here.
func TestPrintSkillUsage(t *testing.T) {
	var buf bytes.Buffer
	printSkillUsage(&buf)
	out := buf.String()
	for _, want := range []string{
		"Usage: x-x skill <subcommand>",
		"remove --user",
		"remove --project",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("usage missing %q in %q", want, out)
		}
	}
}

// TestRemoveScopeRoot_User maps --user to $HOME and labels it "user".
// The label is what the operator log line prints — keep it stable.
func TestRemoveScopeRoot_User(t *testing.T) {
	home := pinHome(t)
	root, label, err := removeScopeRoot(true)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if root != home {
		t.Fatalf("root = %q, want %q", root, home)
	}
	if label != "user" {
		t.Fatalf("label = %q, want user", label)
	}
}

// TestRemoveScopeRoot_Project maps --project to cwd. The EvalSymlinks
// dance handles macOS, where /var/.../T resolves to /private/var/.../T;
// without it the equality check would spuriously fail under TMPDIR.
func TestRemoveScopeRoot_Project(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	root, label, err := removeScopeRoot(false)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	// Resolve symlinks on both sides — macOS /var → /private/var.
	want, _ := filepath.EvalSymlinks(dir)
	got, _ := filepath.EvalSymlinks(root)
	if got != want {
		t.Fatalf("root = %q, want %q", got, want)
	}
	if label != "project" {
		t.Fatalf("label = %q, want project", label)
	}
}

// TestRemoveIfEmpty_RemovesEmpty covers the cleanup case for parent
// `skills/` dirs — once their last owned child is removed, the empty
// shell should follow so we don't leave stale empties behind.
func TestRemoveIfEmpty_RemovesEmpty(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "empty")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := removeIfEmpty(dir); err != nil {
		t.Fatalf("removeIfEmpty: %v", err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("expected dir removed, err=%v", err)
	}
}

// TestRemoveIfEmpty_KeepsNonEmpty pins the user-content safety: if any
// entry is left after our removals (a stray file, a sibling user
// skill), the parent dir must survive untouched.
func TestRemoveIfEmpty_KeepsNonEmpty(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "x"), nil, 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := removeIfEmpty(dir); err != nil {
		t.Fatalf("removeIfEmpty: %v", err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("non-empty dir was removed: %v", err)
	}
}

// TestRemoveIfEmpty_MissingDir confirms removeIfEmpty surfaces errors
// (rather than silently no-op'ing) when its target is absent — the
// caller logs the diagnostic; swallowing it would hide permission bugs.
func TestRemoveIfEmpty_MissingDir(t *testing.T) {
	if err := removeIfEmpty(filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Fatal("expected error for missing dir")
	}
}

// TestRemoveOurSkillsIn_OnlyRemovesAllowlist is the core safety
// contract: a user-authored skill sitting next to ours under the same
// `skills/` parent MUST survive removal. Names not on the allowlist
// are sacred.
func TestRemoveOurSkillsIn_OnlyRemovesAllowlist(t *testing.T) {
	skillsDir := t.TempDir()
	// One x-x-owned skill (skillXXDir), one user-authored fixture. Real
	// dirs on disk to mirror how installSkill lays things out.
	const userFixture = "my-skill"
	for _, name := range []string{skillXXDir, userFixture} {
		p := filepath.Join(skillsDir, name)
		if err := os.MkdirAll(p, 0o700); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
		if err := os.WriteFile(filepath.Join(p, "f"), nil, 0o600); err != nil {
			t.Fatalf("seed file in %s: %v", name, err)
		}
	}
	owned := map[string]bool{skillXXDir: true}
	removed, skipped := removeOurSkillsIn(skillsDir, "test-agent", owned)
	if removed != 1 {
		t.Fatalf("removed = %d, want 1", removed)
	}
	if skipped != 0 {
		t.Fatalf("skipped = %d, want 0", skipped)
	}
	if _, err := os.Stat(filepath.Join(skillsDir, skillXXDir)); !os.IsNotExist(err) {
		t.Fatalf("%s should be removed, err=%v", skillXXDir, err)
	}
	if _, err := os.Stat(filepath.Join(skillsDir, userFixture)); err != nil {
		t.Fatalf("user skill must survive: %v", err)
	}
}

// TestRemoveOurSkillsIn_RemovesEmptyParent ties skill removal and
// parent cleanup together: removing the last owned child must trigger
// the empty-parent cleanup pass.
func TestRemoveOurSkillsIn_RemovesEmptyParent(t *testing.T) {
	parent := filepath.Join(t.TempDir(), skillsSubdir)
	if err := os.MkdirAll(filepath.Join(parent, skillXXDir), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	owned := map[string]bool{skillXXDir: true}
	removeOurSkillsIn(parent, "test", owned)
	// Parent had only the owned dir; after removal it should be cleared too.
	if _, err := os.Stat(parent); !os.IsNotExist(err) {
		t.Fatalf("empty parent should be removed, err=%v", err)
	}
}

// TestRemoveOurSkillsIn_MissingDirIsSilent matches the "agent never had
// an install at this scope" reality: running skill remove against a
// scope that was never init'd must be a clean no-op, not an error.
func TestRemoveOurSkillsIn_MissingDirIsSilent(t *testing.T) {
	owned := map[string]bool{skillXXDir: true}
	removed, skipped := removeOurSkillsIn(filepath.Join(t.TempDir(), "nope"), "t", owned)
	if removed != 0 || skipped != 0 {
		t.Fatalf("missing dir should be a silent no-op, got removed=%d skipped=%d", removed, skipped)
	}
}

// TestRunSkillRemove_EndToEnd_UserScope drives the full --user CLI
// path: both agent targets (Claude + Codex) get walked, ours go, user
// content stays. The check across both targets catches a regression
// where the removal loop skips one agent.
func TestRunSkillRemove_EndToEnd_UserScope(t *testing.T) {
	home := pinHome(t)
	chdir(t, t.TempDir())
	// Seed both agents' skill dirs (walking the registry, not literals)
	// with one bundled + one user fixture.
	const userFixture = "user-skill"
	for _, target := range agentTargets {
		for _, name := range []string{skillXXDir, userFixture} {
			if err := os.MkdirAll(filepath.Join(home, target.skillsRel, name), 0o700); err != nil {
				t.Fatalf("seed: %v", err)
			}
		}
	}
	runSkillRemove([]string{"--user"})
	for _, target := range agentTargets {
		if _, err := os.Stat(filepath.Join(home, target.skillsRel, skillXXDir)); !os.IsNotExist(err) {
			t.Fatalf("%s/%s should be removed, err=%v", target.skillsRel, skillXXDir, err)
		}
		if _, err := os.Stat(filepath.Join(home, target.skillsRel, userFixture)); err != nil {
			t.Fatalf("%s/%s must survive: %v", target.skillsRel, userFixture, err)
		}
	}
}
