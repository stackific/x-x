// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPrintSkillsUsage guards the `stax skills` help surface — the two
// remove flags must both appear, so adding a third without updating the
// help block fails here.
func TestPrintSkillsUsage(t *testing.T) {
	var buf bytes.Buffer
	printSkillsUsage(&buf)
	out := buf.String()
	for _, want := range []string{
		"Usage: stax skills <subcommand>",
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
	// One stax-owned skill (skillShipDir), one user-authored fixture. Real
	// dirs on disk to mirror how installSkill lays things out.
	const userFixture = "my-skill"
	for _, name := range []string{skillShipDir, userFixture} {
		p := filepath.Join(skillsDir, name)
		if err := os.MkdirAll(p, 0o700); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
		if err := os.WriteFile(filepath.Join(p, "f"), nil, 0o600); err != nil {
			t.Fatalf("seed file in %s: %v", name, err)
		}
	}
	owned := map[string]bool{skillShipDir: true}
	removed, skipped := removeOurSkillsIn(skillsDir, "test-agent", owned)
	if removed != 1 {
		t.Fatalf("removed = %d, want 1", removed)
	}
	if skipped != 0 {
		t.Fatalf("skipped = %d, want 0", skipped)
	}
	if _, err := os.Stat(filepath.Join(skillsDir, skillShipDir)); !os.IsNotExist(err) {
		t.Fatalf("%s should be removed, err=%v", skillShipDir, err)
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
	if err := os.MkdirAll(filepath.Join(parent, skillShipDir), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	owned := map[string]bool{skillShipDir: true}
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
	owned := map[string]bool{skillShipDir: true}
	removed, skipped := removeOurSkillsIn(filepath.Join(t.TempDir(), "nope"), "t", owned)
	if removed != 0 || skipped != 0 {
		t.Fatalf("missing dir should be a silent no-op, got removed=%d skipped=%d", removed, skipped)
	}
}

// hookFixtureJSON is the standard settings.json/hooks.json structure used by
// the un-merge tests. The bundled side ships exactly one record; the user
// side has the same record (deep-equal) plus a hand-written sibling under
// the same event key, plus a user-added event key the bundle never ships.
// Run through subtractHooks/removeBundledHooksIn, only the deep-equal
// record should disappear.
func hookFixtureJSON(t *testing.T) (bundle, user string) {
	t.Helper()
	bundle = `{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "stax plans lint"}]}
    ]
  }
}
`
	user = `{
  "fastMode": true,
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "stax plans lint"}]},
      {"matcher": "Bash",       "hooks": [{"type": "command", "command": "my-tool"}]}
    ],
    "UserPromptSubmit": [
      {"matcher": "",           "hooks": [{"type": "command", "command": "user-only"}]}
    ]
  }
}
`
	return bundle, user
}

// decodeJSON parses raw into a generic Go value. Failures are fatal — the
// fixtures are hand-written, so any parse error is a test bug.
func decodeJSON(t *testing.T, raw string) any {
	t.Helper()
	var out any
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return out
}

// TestSubtractHooks_DropsDeepEqualRecord proves the core un-merge rule:
// a user entry that byte-equals a bundled entry is dropped, leaving the
// user's own sibling alongside it intact. The user-added event key
// (UserPromptSubmit) — never present in the bundle — must also survive.
func TestSubtractHooks_DropsDeepEqualRecord(t *testing.T) {
	bundleRaw, userRaw := hookFixtureJSON(t)
	bundle := decodeJSON(t, bundleRaw).(map[string]any)[configHooksKey]
	user := decodeJSON(t, userRaw).(map[string]any)[configHooksKey]

	got, changed := subtractHooks(user, bundle)
	if !changed {
		t.Fatal("changed = false, want true (one matching record present)")
	}
	gotMap := got.(map[string]any)
	postToolUse := gotMap["PostToolUse"].([]any)
	if len(postToolUse) != 1 {
		t.Fatalf("PostToolUse len = %d, want 1 (only user-authored Bash entry should remain)", len(postToolUse))
	}
	if m := postToolUse[0].(map[string]any)["matcher"]; m != "Bash" {
		t.Fatalf("surviving entry matcher = %q, want Bash", m)
	}
	if _, ok := gotMap["UserPromptSubmit"]; !ok {
		t.Fatal("user-added event key UserPromptSubmit was dropped")
	}
}

// TestSubtractHooks_PreservesUserTweakedVariant is the safety pin against
// any future temptation to recurse into individual records. A user-modified
// command string fails deep-equality with the bundle, and must therefore
// survive the un-merge untouched. The unit of ownership is the leaf record.
func TestSubtractHooks_PreservesUserTweakedVariant(t *testing.T) {
	bundle := decodeJSON(t, `{"hooks":{"PostToolUse":[{"matcher":"Write|Edit","hooks":[{"type":"command","command":"stax plans lint"}]}]}}`).(map[string]any)[configHooksKey]
	user := decodeJSON(t, `{"hooks":{"PostToolUse":[{"matcher":"Write|Edit","hooks":[{"type":"command","command":"stax plans lint --verbose"}]}]}}`).(map[string]any)[configHooksKey]

	got, changed := subtractHooks(user, bundle)
	if changed {
		t.Fatal("changed = true; user-tweaked record should not deep-equal bundled")
	}
	arr := got.(map[string]any)["PostToolUse"].([]any)
	if len(arr) != 1 {
		t.Fatalf("len = %d, want 1 (tweaked entry must survive)", len(arr))
	}
}

// TestSubtractHooks_NoOpWhenNotMap pins the "type-mismatch is preserved"
// contract: a non-map "hooks" value (someone put an array or null there)
// must not be silently rewritten. We refuse to touch structures we don't
// understand rather than guess.
func TestSubtractHooks_NoOpWhenNotMap(t *testing.T) {
	cases := []struct {
		name          string
		user, bundled any
	}{
		{"user is array", []any{1, 2}, map[string]any{}},
		{"bundled is nil", map[string]any{}, nil},
		{"user is nil", nil, map[string]any{}},
		{"both scalars", "x", "y"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, changed := subtractHooks(c.user, c.bundled)
			if changed {
				t.Fatalf("changed = true, want false")
			}
			if !jsonDeepEqual(got, c.user) {
				t.Fatalf("user value mutated: got %v, want %v", got, c.user)
			}
		})
	}
}

// TestSubtractHooks_BundledEventKeyMissingInUser ensures the loop is
// driven by the bundled keys (no fabrication of empty arrays in user when
// it lacks an event key the bundle ships).
func TestSubtractHooks_BundledEventKeyMissingInUser(t *testing.T) {
	bundle := decodeJSON(t, `{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"stax plans lint"}]}]}}`).(map[string]any)[configHooksKey]
	user := decodeJSON(t, `{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine"}]}]}}`).(map[string]any)[configHooksKey]

	got, changed := subtractHooks(user, bundle)
	if changed {
		t.Fatal("changed = true; user had nothing matching the bundle")
	}
	gotMap := got.(map[string]any)
	if _, ok := gotMap["Stop"]; ok {
		t.Fatal("Stop key fabricated in user output; bundled-only keys must not appear")
	}
	if len(gotMap["PostToolUse"].([]any)) != 1 {
		t.Fatal("user-only PostToolUse was disturbed")
	}
}

// TestRemoveBundledHooksIn_DropsOursKeepsTheirs is the full file-I/O
// path: seed a bundle JSON + a user JSON with mixed ownership, run the
// un-merge, parse the result and assert exactly the deep-equal record is
// gone. Uses hookFixtureJSON for the standard structure.
func TestRemoveBundledHooksIn_DropsOursKeepsTheirs(t *testing.T) {
	tmp := t.TempDir()
	bundleSrc := filepath.Join(tmp, "bundle")
	userDest := filepath.Join(tmp, "user")
	if err := os.MkdirAll(bundleSrc, 0o700); err != nil {
		t.Fatalf("mkdir bundle: %v", err)
	}
	if err := os.MkdirAll(userDest, 0o700); err != nil {
		t.Fatalf("mkdir user: %v", err)
	}
	bundleRaw, userRaw := hookFixtureJSON(t)
	const fname = "settings" + configJSONExt
	if err := os.WriteFile(filepath.Join(bundleSrc, fname), []byte(bundleRaw), 0o600); err != nil {
		t.Fatalf("write bundle: %v", err)
	}
	if err := os.WriteFile(filepath.Join(userDest, fname), []byte(userRaw), 0o600); err != nil {
		t.Fatalf("write user: %v", err)
	}
	modified, skipped := removeBundledHooksIn(bundleSrc, userDest, "TestAgent")
	if modified != 1 {
		t.Fatalf("modified = %d, want 1", modified)
	}
	if skipped != 0 {
		t.Fatalf("skipped = %d, want 0", skipped)
	}
	gotRaw, err := os.ReadFile(filepath.Join(userDest, fname))
	if err != nil {
		t.Fatalf("read result: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(gotRaw, &got); err != nil {
		t.Fatalf("parse result: %v", err)
	}
	// Top-level non-hook keys must survive untouched.
	if v, ok := got["fastMode"]; !ok || v != true {
		t.Fatalf("fastMode lost: %v", got)
	}
	hooks := got[configHooksKey].(map[string]any)
	pt := hooks["PostToolUse"].([]any)
	if len(pt) != 1 {
		t.Fatalf("PostToolUse len = %d, want 1", len(pt))
	}
	if pt[0].(map[string]any)["matcher"] != "Bash" {
		t.Fatalf("survivor is not the user-authored Bash entry: %v", pt[0])
	}
	if _, ok := hooks["UserPromptSubmit"]; !ok {
		t.Fatal("user-added event key UserPromptSubmit was removed")
	}
}

// TestRemoveBundledHooksIn_MissingUserFileIsSilent matches the "agent
// config never installed at this scope" reality: when the user has no
// JSON file at all, the un-merge is a clean no-op, no diagnostic.
func TestRemoveBundledHooksIn_MissingUserFileIsSilent(t *testing.T) {
	tmp := t.TempDir()
	bundleSrc := filepath.Join(tmp, "bundle")
	if err := os.MkdirAll(bundleSrc, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	bundleRaw, _ := hookFixtureJSON(t)
	const fname = "settings" + configJSONExt
	if err := os.WriteFile(filepath.Join(bundleSrc, fname), []byte(bundleRaw), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	// userDest exists as a dir but contains no JSON file.
	userDest := filepath.Join(tmp, "user")
	if err := os.MkdirAll(userDest, 0o700); err != nil {
		t.Fatalf("mkdir user: %v", err)
	}
	modified, skipped := removeBundledHooksIn(bundleSrc, userDest, "TestAgent")
	if modified != 0 || skipped != 0 {
		t.Fatalf("missing user file should be a silent no-op, got modified=%d skipped=%d", modified, skipped)
	}
}

// TestRemoveBundledHooksIn_MissingBundleIsSilent covers the case where
// ensureBundledAgents hasn't run yet (or this agent ships no config dir).
// Must return cleanly without scanning anything.
func TestRemoveBundledHooksIn_MissingBundleIsSilent(t *testing.T) {
	modified, skipped := removeBundledHooksIn(filepath.Join(t.TempDir(), "absent"), t.TempDir(), "T")
	if modified != 0 || skipped != 0 {
		t.Fatalf("missing bundle should be a silent no-op, got modified=%d skipped=%d", modified, skipped)
	}
}

// TestRemoveBundledHooksIn_MalformedUserJSON pins the failure mode: a
// user file we can't parse is left strictly alone. Skipped count
// increments so the operator sees the issue in the summary.
func TestRemoveBundledHooksIn_MalformedUserJSON(t *testing.T) {
	tmp := t.TempDir()
	bundleSrc := filepath.Join(tmp, "bundle")
	userDest := filepath.Join(tmp, "user")
	for _, d := range []string{bundleSrc, userDest} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	bundleRaw, _ := hookFixtureJSON(t)
	const fname = "settings" + configJSONExt
	if err := os.WriteFile(filepath.Join(bundleSrc, fname), []byte(bundleRaw), 0o600); err != nil {
		t.Fatalf("write bundle: %v", err)
	}
	garbage := []byte("{ this is not json")
	userPath := filepath.Join(userDest, fname)
	if err := os.WriteFile(userPath, garbage, 0o600); err != nil {
		t.Fatalf("write user: %v", err)
	}
	modified, skipped := removeBundledHooksIn(bundleSrc, userDest, "T")
	if modified != 0 {
		t.Fatalf("modified = %d, want 0 (parse failure must not write)", modified)
	}
	if skipped != 1 {
		t.Fatalf("skipped = %d, want 1", skipped)
	}
	// User file bytes must be untouched after the skip — the operator's
	// hand-written content (even if malformed) is sacred.
	gotRaw, err := os.ReadFile(userPath)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(gotRaw, garbage) {
		t.Fatalf("user file mutated after malformed-skip: got %q", gotRaw)
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
		for _, name := range []string{skillShipDir, userFixture} {
			if err := os.MkdirAll(filepath.Join(home, target.skillsRel, name), 0o700); err != nil {
				t.Fatalf("seed: %v", err)
			}
		}
	}
	runSkillsRemove([]string{"--user"})
	for _, target := range agentTargets {
		if _, err := os.Stat(filepath.Join(home, target.skillsRel, skillShipDir)); !os.IsNotExist(err) {
			t.Fatalf("%s/%s should be removed, err=%v", target.skillsRel, skillShipDir, err)
		}
		if _, err := os.Stat(filepath.Join(home, target.skillsRel, userFixture)); err != nil {
			t.Fatalf("%s/%s must survive: %v", target.skillsRel, userFixture, err)
		}
	}
}

// TestRunSkillRemove_EndToEnd_HookUnmerge exercises the hook un-merge
// through the full --user CLI: seeds a bundled config JSON under
// ~/.stax/agents/<agent>/ and a user JSON with a deep-equal record + a
// hand-written sibling under the same event key. After remove, the
// deep-equal record must be gone and the user's sibling must survive.
// Iterates agentTargets so a future third agent gets exercised
// automatically.
func TestRunSkillRemove_EndToEnd_HookUnmerge(t *testing.T) {
	home := pinHome(t)
	chdir(t, t.TempDir())
	const fname = "settings" + configJSONExt
	for i := range agentTargets {
		if agentTargets[i].configSrc != "" {
			seedHookFixture(t, home, &agentTargets[i], fname)
		}
	}
	runSkillsRemove([]string{"--user"})
	for i := range agentTargets {
		if agentTargets[i].configSrc != "" {
			assertHookUnmergeResult(t, home, &agentTargets[i], fname)
		}
	}
}

// seedHookFixture lays down one agent's bundle file + user counterpart on
// the pinned $HOME. Both files use hookFixtureJSON's structure so the bundled
// record deep-equals the matching user record after JSON round-trip.
func seedHookFixture(t *testing.T, home string, target *agentTarget, fname string) {
	t.Helper()
	bundleRaw, userRaw := hookFixtureJSON(t)
	bundleDir := filepath.Join(home, staxDir, agentsEmbedRoot, target.configSrc)
	userDir := filepath.Join(home, target.configRel)
	for _, d := range []string{bundleDir, userDir} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatalf("mkdir %s: %v", d, err)
		}
	}
	if err := os.WriteFile(filepath.Join(bundleDir, fname), []byte(bundleRaw), 0o600); err != nil {
		t.Fatalf("seed bundle %s: %v", target.key, err)
	}
	if err := os.WriteFile(filepath.Join(userDir, fname), []byte(userRaw), 0o600); err != nil {
		t.Fatalf("seed user %s: %v", target.key, err)
	}
}

// assertHookUnmergeResult parses the post-run user file for one agent and
// pins the contract: top-level fastMode survives, the single surviving
// PostToolUse entry is the user-authored Bash record, and the deep-equal
// bundled record is gone.
func assertHookUnmergeResult(t *testing.T, home string, target *agentTarget, fname string) {
	t.Helper()
	got, err := os.ReadFile(filepath.Join(home, target.configRel, fname))
	if err != nil {
		t.Fatalf("read %s result: %v", target.key, err)
	}
	var parsed map[string]any
	if err := json.Unmarshal(got, &parsed); err != nil {
		t.Fatalf("%s: parse result: %v", target.key, err)
	}
	if v, ok := parsed["fastMode"]; !ok || v != true {
		t.Fatalf("%s: fastMode lost", target.key)
	}
	pt := parsed[configHooksKey].(map[string]any)["PostToolUse"].([]any)
	if len(pt) != 1 {
		t.Fatalf("%s: PostToolUse len = %d, want 1", target.key, len(pt))
	}
	if m := pt[0].(map[string]any)["matcher"]; m != "Bash" {
		t.Fatalf("%s: surviving matcher = %q, want Bash", target.key, m)
	}
}
