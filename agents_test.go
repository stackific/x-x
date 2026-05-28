// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"
)

// pinHome redirects os.UserHomeDir() at $HOME for the duration of the test.
// On Linux/macOS UserHomeDir consults $HOME first, so this is sufficient
// isolation; on Windows the env var is USERPROFILE — covered separately if
// the test ever runs on that platform.
func pinHome(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	// USERPROFILE for the Windows fallback. Harmless on POSIX.
	t.Setenv("USERPROFILE", tmp)
	return tmp
}

// TestAgentsTarget confirms agentsTarget composes the path from $HOME +
// staxDir + agentsEmbedRoot rather than hard-coding any segment. A
// rename of any of those three constants must show up here.
func TestAgentsTarget(t *testing.T) {
	home := pinHome(t)
	got, err := agentsTarget()
	if err != nil {
		t.Fatalf("agentsTarget: %v", err)
	}
	want := filepath.Join(home, staxDir, agentsEmbedRoot)
	if got != want {
		t.Fatalf("agentsTarget = %q, want %q", got, want)
	}
}

// TestEnsureAgentsDir_Materializes covers the cold-start lazy bootstrap:
// when ~/.stax/agents/ doesn't exist, the first call must create it and
// populate the embedded skill tree. Checks at least one known skill dir
// lands so an empty-embed regression would fail.
func TestEnsureAgentsDir_Materializes(t *testing.T) {
	home := pinHome(t)
	if err := ensureBundledAgents(); err != nil {
		t.Fatalf("ensureBundledAgents: %v", err)
	}
	target := filepath.Join(home, staxDir, agentsEmbedRoot)
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("expected %s to exist: %v", target, err)
	}
	// Sanity-check one bundled skill landed.
	if _, err := os.Stat(filepath.Join(target, skillsSubdir, skillShipDir)); err != nil {
		t.Fatalf("expected bundled skill %s: %v", skillShipDir, err)
	}
}

// TestEnsureAgentsDir_Idempotent verifies the second-call no-op contract:
// once ~/.stax/agents/ exists, ensureBundledAgents must NOT re-materialize
// (we plant a sentinel and check it survives). This is what lets every
// bare `stax` invocation be cheap.
func TestEnsureAgentsDir_Idempotent(t *testing.T) {
	home := pinHome(t)
	if err := ensureBundledAgents(); err != nil {
		t.Fatalf("first ensureBundledAgents: %v", err)
	}
	// Drop a sentinel file to detect an unwanted re-materialize.
	sentinel := filepath.Join(home, staxDir, agentsEmbedRoot, "sentinel")
	if err := os.WriteFile(sentinel, []byte("x"), 0o600); err != nil {
		t.Fatalf("write sentinel: %v", err)
	}
	if err := ensureBundledAgents(); err != nil {
		t.Fatalf("second ensureBundledAgents: %v", err)
	}
	if _, err := os.Stat(sentinel); err != nil {
		t.Fatalf("sentinel removed — ensureBundledAgents should be a no-op when target exists: %v", err)
	}
}

// TestMaterializeAgents_Force_Clobbers pins the `overwrite=true` semantics
// used by `stax bootstrap` and the 24h refresh path: any stale content
// under ~/.stax/agents/ must be wiped before the embed is rewritten, so
// the result is byte-identical to the binary's bundle.
func TestMaterializeAgents_Force_Clobbers(t *testing.T) {
	home := pinHome(t)
	if err := writeBundledAgents(false); err != nil {
		t.Fatalf("writeBundledAgents(false): %v", err)
	}
	sentinel := filepath.Join(home, staxDir, agentsEmbedRoot, "sentinel")
	if err := os.WriteFile(sentinel, []byte("x"), 0o600); err != nil {
		t.Fatalf("write sentinel: %v", err)
	}
	if err := writeBundledAgents(true); err != nil {
		t.Fatalf("writeBundledAgents(true): %v", err)
	}
	if _, err := os.Stat(sentinel); !os.IsNotExist(err) {
		t.Fatalf("expected sentinel to be removed by force materialize, got err=%v", err)
	}
}

// TestMaterializeAgents_SkipsEmbedReadme covers the skipFromEmbed
// allowlist — repo-only files (README.md is the lone entry today) must
// stay in the embed but never land on the user's disk.
func TestMaterializeAgents_SkipsEmbedReadme(t *testing.T) {
	home := pinHome(t)
	if err := writeBundledAgents(true); err != nil {
		t.Fatalf("writeBundledAgents: %v", err)
	}
	// skipFromEmbed lists README.md at the embed root.
	stray := filepath.Join(home, staxDir, agentsEmbedRoot, "README.md")
	if _, err := os.Stat(stray); !os.IsNotExist(err) {
		t.Fatalf("expected agents/README.md to be skipped, got err=%v", err)
	}
}

// TestMaterializeAgents_PopulatesAllBundledSkills cross-checks the
// ownedSkills allowlist against the materialized tree — every name on
// the allowlist must land as a real directory. Catches the case where
// someone deletes a skill from agents/skills/ but forgets ownedSkills.
func TestMaterializeAgents_PopulatesAllBundledSkills(t *testing.T) {
	home := pinHome(t)
	if err := writeBundledAgents(true); err != nil {
		t.Fatalf("writeBundledAgents: %v", err)
	}
	for _, skill := range ownedSkills {
		p := filepath.Join(home, staxDir, agentsEmbedRoot, skillsSubdir, skill)
		info, err := os.Stat(p)
		if err != nil {
			t.Fatalf("missing bundled skill %s: %v", skill, err)
		}
		if !info.IsDir() {
			t.Fatalf("expected %s to be a directory", p)
		}
	}
}

// TestCopyEmbeddedFile_CreatesParentDirs verifies copyEmbeddedFile is
// resilient when its dest path includes intermediate directories that
// don't exist yet — important because the walk callback can visit a
// file before its parent dir has been materialized in pathological cases.
func TestCopyEmbeddedFile_CreatesParentDirs(t *testing.T) {
	home := pinHome(t)
	// Reuse a real embedded file path. embed.FS uses forward slashes
	// regardless of OS, so path.Join (not filepath.Join) is correct here.
	srcEmbed := path.Join(agentsEmbedRoot, skillsSubdir, skillShipDir, skillManifestFile)
	if _, err := embeddedAgents.Open(srcEmbed); err != nil {
		t.Skipf("embed missing %s (no bundled manifest to round-trip): %v", srcEmbed, err)
	}
	dest := filepath.Join(home, "deep", "nested", "out"+planFileExt)
	if err := copyEmbeddedFile(srcEmbed, dest); err != nil {
		t.Fatalf("copyEmbeddedFile: %v", err)
	}
	if !strings.HasPrefix(dest, home) {
		t.Fatalf("dest escaped HOME: %s", dest)
	}
	if _, err := os.Stat(dest); err != nil {
		t.Fatalf("dest missing: %v", err)
	}
}

// TestCopyEmbeddedFile_MissingSource pins error propagation: a missing
// embed-side path must surface a non-nil error rather than silently
// producing an empty dest file — silent success would hide a corrupted
// or mis-named embed at install time.
func TestCopyEmbeddedFile_MissingSource(t *testing.T) {
	pinHome(t)
	err := copyEmbeddedFile(path.Join(agentsEmbedRoot, "does-not-exist"), filepath.Join(t.TempDir(), "x"))
	if err == nil {
		t.Fatal("expected error for missing embed source")
	}
}
