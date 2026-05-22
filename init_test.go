// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// chdir is a t-scoped Chdir: restores the original cwd at test cleanup so
// follow-on tests aren't surprised by a lingering working directory.
func chdir(t *testing.T, dir string) {
	t.Helper()
	orig, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("chdir %s: %v", dir, err)
	}
	t.Cleanup(func() { _ = os.Chdir(orig) })
}

// TestPromptScope_Project covers the canonical "1" → scopeProject mapping.
// The numeric encoding is part of the user contract (printed in the prompt),
// so any silent renumber would break scripted installs piping "1\n".
func TestPromptScope_Project(t *testing.T) {
	got, err := promptScope(strings.NewReader("1\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != scopeProject {
		t.Fatalf("got %v, want scopeProject", got)
	}
}

// TestPromptScope_User is the sibling of _Project: "2" → scopeUser. The
// two values together exhaust the encoding; a new scope (e.g. workspace)
// would also need a new test.
func TestPromptScope_User(t *testing.T) {
	got, err := promptScope(strings.NewReader("2\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != scopeUser {
		t.Fatalf("got %v, want scopeUser", got)
	}
}

// TestPromptScope_TrimsWhitespace tolerates the common "  1  \n" pattern
// — terminal copy-paste and CR/LF normalization both produce stray
// surrounding whitespace that shouldn't reject the choice.
func TestPromptScope_TrimsWhitespace(t *testing.T) {
	got, err := promptScope(strings.NewReader("  1  \n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != scopeProject {
		t.Fatalf("got %v, want scopeProject", got)
	}
}

// TestPromptScope_NoTrailingNewline covers the io.EOF-after-content case:
// ReadString returns "2", io.EOF together when stdin closes without a
// final newline. We must honor the choice instead of erroring — heredoc
// callers and `printf` (without -n) routinely hit this shape.
func TestPromptScope_NoTrailingNewline(t *testing.T) {
	// ReadString returns the line + io.EOF when the input has no newline;
	// promptScope is expected to honor the choice in that case.
	got, err := promptScope(strings.NewReader("2"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != scopeUser {
		t.Fatalf("got %v, want scopeUser", got)
	}
}

// TestPromptScope_Invalid pins the strict-validation path: anything that
// isn't "1" or "2" must error rather than fall back to a default.
// runInit relies on this to bail before any disk side effects start.
func TestPromptScope_Invalid(t *testing.T) {
	if _, err := promptScope(strings.NewReader("9\n")); err == nil {
		t.Fatal("expected error for invalid choice")
	}
}

// TestPromptScope_Empty rejects EOF-with-no-input. Distinct from
// promptAgents (which defaults to all on empty) — for scope there's no
// sensible default, so the function MUST error rather than guess.
func TestPromptScope_Empty(t *testing.T) {
	if _, err := promptScope(strings.NewReader("")); err == nil {
		t.Fatal("expected error for empty input")
	}
}

// ---------- project gate ----------

// TestCheckProject_DirPresent is the happy path: with .x-plan/ present,
// the gate passes and project-level subcommands proceed.
func TestCheckProject_DirPresent(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, planDir), 0o700); err != nil {
		t.Fatalf("seed planDir: %v", err)
	}
	chdir(t, dir)
	if err := checkProject(); err != nil {
		t.Fatalf("expected nil, got %v", err)
	}
}

// TestCheckProject_MissingDir pins both the failure trigger (no .x-plan/)
// AND the diagnostic shape — callers' tests look for "not an x-x project"
// + the planDir name, so changing either substring would silently break
// the e2e assertions.
func TestCheckProject_MissingDir(t *testing.T) {
	chdir(t, t.TempDir())
	err := checkProject()
	if err == nil {
		t.Fatal("expected error when planDir is missing")
	}
	if !strings.Contains(err.Error(), "not an x-x project") {
		t.Fatalf("message = %q, want it to mention 'not an x-x project'", err.Error())
	}
	if !strings.Contains(err.Error(), planDir) {
		t.Fatalf("message = %q, want it to mention planDir %q", err.Error(), planDir)
	}
}

// TestCheckProject_PlanIsFileNotDir hardens the gate against the
// pathological case where `.x-plan` exists but as a regular file — must
// still fail, since `os.ReadDir` on a file would crash the downstream
// plan-list / next-prefix logic.
func TestCheckProject_PlanIsFileNotDir(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, planDir), nil, 0o600); err != nil {
		t.Fatalf("seed file: %v", err)
	}
	chdir(t, dir)
	if err := checkProject(); err == nil {
		t.Fatal("expected error when planDir is a regular file")
	}
}

// ---------- agents picker ----------

// agentKeys is a tiny helper that flattens the picker's result into a
// stable, comparable string so assertions can read as plain English.
func agentKeys(ts []agentTarget) string {
	keys := make([]string, len(ts))
	for i, t := range ts {
		keys[i] = t.key
	}
	return strings.Join(keys, ",")
}

// TestPromptAgents_EmptyDefaultsToAll covers the EOF-with-no-input case
// for the agents picker. This is what keeps scripted callers piping just
// `--scope project` working after the agents prompt was inserted in front
// of the scope prompt.
func TestPromptAgents_EmptyDefaultsToAll(t *testing.T) {
	got, err := promptAgents(strings.NewReader(""))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	allKeys := make([]string, len(agentTargets))
	for i, t := range agentTargets {
		allKeys[i] = t.key
	}
	if agentKeys(got) != strings.Join(allKeys, ",") {
		t.Fatalf("got %q want %q", agentKeys(got), strings.Join(allKeys, ","))
	}
}

// TestPromptAgents_BlankLineDefaultsToAll is the interactive analog of
// the empty-stdin case: a user pressing Enter at the prompt accepts the
// "all agents" default, no error.
func TestPromptAgents_BlankLineDefaultsToAll(t *testing.T) {
	got, err := promptAgents(strings.NewReader("   \n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != len(agentTargets) {
		t.Fatalf("got %d, want all %d", len(got), len(agentTargets))
	}
}

// TestPromptAgents_SinglePick exercises the simplest non-default input:
// one number, one selected agent. Asserts against agentTargets[0].key
// so the test tracks any future renaming of the Claude row.
func TestPromptAgents_SinglePick(t *testing.T) {
	got, err := promptAgents(strings.NewReader("1\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if agentKeys(got) != agentTargets[0].key {
		t.Fatalf("got %q want %q", agentKeys(got), agentTargets[0].key)
	}
}

func TestPromptAgents_MultiPick_PreservesRegistryOrder(t *testing.T) {
	// User types "2,1" but the result must still be in registry order
	// (so the install loop's progress output is deterministic).
	got, err := promptAgents(strings.NewReader("2,1\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	want := agentTargets[0].key + "," + agentTargets[1].key
	if agentKeys(got) != want {
		t.Fatalf("got %q want %q", agentKeys(got), want)
	}
}

// TestPromptAgents_OutOfRange rejects numbers outside `1..len(agentTargets)`.
// Silent fall-through would surprise the user with an unexpected agent
// selection; the function must error and let runInit bail.
func TestPromptAgents_OutOfRange(t *testing.T) {
	if _, err := promptAgents(strings.NewReader("9\n")); err == nil {
		t.Fatal("expected error for out-of-range pick")
	}
}

// TestPromptAgents_NonNumeric covers the "typed the key instead of the
// number" case. Two valid input shapes are easy to confuse, so the prompt
// must error rather than guess — the user should retry.
func TestPromptAgents_NonNumeric(t *testing.T) {
	if _, err := promptAgents(strings.NewReader("claude\n")); err == nil {
		t.Fatal("expected error for non-numeric pick")
	}
}

// TestResolveAgentsFromKeys is the table-driven coverage for the
// non-interactive flag path. Cases capture: single key, both keys,
// caller-provided order doesn't matter (registry order wins), unknown
// keys error, all-blank input errors, repeated keys dedupe silently.
func TestResolveAgentsFromKeys(t *testing.T) {
	cases := []struct {
		name    string
		keys    []string
		want    string // comma-joined keys
		wantErr bool
	}{
		{"single", []string{"claude"}, "claude", false},
		{"both", []string{"claude", "codex"}, "claude,codex", false},
		{"registry order", []string{"codex", "claude"}, "claude,codex", false},
		{"unknown", []string{"gemini"}, "", true},
		{"all blank", []string{"", "  "}, "", true},
		{"dedup", []string{"claude", "claude"}, "claude", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := resolveAgentsFromKeys(c.keys)
			if c.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("err: %v", err)
			}
			if agentKeys(got) != c.want {
				t.Fatalf("got %q want %q", agentKeys(got), c.want)
			}
		})
	}
}

// TestResolveAgents_FlagBeatsPrompt enforces "non-interactive when flag
// is set". We pass panicReader to prove the function never reads stdin
// when the flag is non-empty — important for CI installs that have no
// TTY attached.
func TestResolveAgents_FlagBeatsPrompt(t *testing.T) {
	// When --agents is non-empty the function must NOT read from stdin.
	// We pass a reader that would error if touched.
	got, err := resolveAgents([]string{"claude"}, panicReader{})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if agentKeys(got) != "claude" {
		t.Fatalf("got %q want claude", agentKeys(got))
	}
}

// TestResolveAgents_EmptyFlagPromptsAndDefaults covers the inverse: no
// flag → fall into the prompt → empty input → all agents. End-to-end
// shape of the "user runs `x-x init --scope project` piping nothing" path.
func TestResolveAgents_EmptyFlagPromptsAndDefaults(t *testing.T) {
	// Empty flag → prompt path → empty input → all agents.
	got, err := resolveAgents(nil, strings.NewReader(""))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != len(agentTargets) {
		t.Fatalf("got %d agents want all %d", len(got), len(agentTargets))
	}
}

// panicReader fails any read attempt — used to assert that callers do
// NOT touch stdin when they shouldn't.
type panicReader struct{}

func (panicReader) Read([]byte) (int, error) {
	panic("unexpected read")
}

// TestResolveScope is the table-driven combined coverage for the flag +
// prompt resolution. Asymmetric on purpose: flag wins when set; invalid
// flag value errors; empty flag falls through to the stdin prompt.
func TestResolveScope(t *testing.T) {
	cases := []struct {
		flag    string
		stdin   string
		want    initScope
		wantErr bool
	}{
		{"project", "", scopeProject, false},
		{"user", "", scopeUser, false},
		{"", "1\n", scopeProject, false},
		{"", "2\n", scopeUser, false},
		{"workspace", "", 0, true},
		{"", "x\n", 0, true},
	}
	for _, c := range cases {
		got, err := resolveScope(c.flag, strings.NewReader(c.stdin))
		if c.wantErr {
			if err == nil {
				t.Fatalf("flag=%q stdin=%q: expected error, got scope=%v", c.flag, c.stdin, got)
			}
			continue
		}
		if err != nil {
			t.Fatalf("flag=%q stdin=%q: %v", c.flag, c.stdin, err)
		}
		if got != c.want {
			t.Fatalf("flag=%q stdin=%q: got %v want %v", c.flag, c.stdin, got, c.want)
		}
	}
}

// TestScopeRootFor maps the two valid scope enums to their filesystem
// roots and asserts the defensive default-branch error fires for an
// invalid enum value (guards against a future caller passing a
// non-canonical initScope by accident).
func TestScopeRootFor(t *testing.T) {
	home := pinHome(t)
	got, err := scopeRootFor(scopeProject, "/cwd-x")
	if err != nil {
		t.Fatalf("project: %v", err)
	}
	if got != "/cwd-x" {
		t.Fatalf("project = %q, want /cwd-x", got)
	}
	got, err = scopeRootFor(scopeUser, "/cwd-x")
	if err != nil {
		t.Fatalf("user: %v", err)
	}
	if got != home {
		t.Fatalf("user = %q, want %q", got, home)
	}
	if _, err := scopeRootFor(initScope(99), "/x"); err == nil {
		t.Fatal("expected error for invalid scope")
	}
}

// TestListSkills exercises the directory filter logic: regular dirs +
// underscore-prefixed shared dirs pass; dotfiles and regular files are
// excluded. The shared-dir behavior is critical (the bundle includes
// _x-x_shared) so a stricter filter would break the install.
func TestListSkills(t *testing.T) {
	dir := t.TempDir()
	// Bundled-shape sample: regular skill, shared (underscore prefix
	// allowed), a dotfile dir (must be filtered), and a stray file.
	for _, name := range []string{"alpha", "_shared", ".hidden"} {
		if err := os.MkdirAll(filepath.Join(dir, name), 0o700); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "stray.txt"), nil, 0o600); err != nil {
		t.Fatalf("stray: %v", err)
	}
	got, err := listSkills(dir)
	if err != nil {
		t.Fatalf("listSkills: %v", err)
	}
	want := map[string]bool{"alpha": true, "_shared": true}
	if len(got) != 2 {
		t.Fatalf("got %v, want 2 entries", got)
	}
	for _, name := range got {
		if !want[name] {
			t.Fatalf("unexpected skill %q in %v", name, got)
		}
	}
}

// TestListSkills_MissingDir asserts a hard failure when the source dir
// doesn't exist. listSkills is called only after ensureBundledAgents so
// a missing source signals a broken install, not a routine empty state.
func TestListSkills_MissingDir(t *testing.T) {
	if _, err := listSkills(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Fatal("expected error for missing source")
	}
}

// TestListSkills_EmptyDir distinguishes "source exists but empty" from
// "source missing": the former is a clean nil return, not an error.
// runInit branches on the slice length to print "no skills to install".
func TestListSkills_EmptyDir(t *testing.T) {
	got, err := listSkills(t.TempDir())
	if err != nil {
		t.Fatalf("listSkills: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("got %v, want empty", got)
	}
}

// TestWriteIfAbsent is the "create exactly once" primitive: second call
// MUST NOT clobber. This is what makes the plan scaffold's
// `_data_systems.yaml` and `_config.lock` honor user edits across
// re-runs of `x-x init`.
func TestWriteIfAbsent(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "f.txt")
	if err := writeIfAbsent(p, []byte("first")); err != nil {
		t.Fatalf("first write: %v", err)
	}
	// Second call must not clobber.
	if err := writeIfAbsent(p, []byte("second")); err != nil {
		t.Fatalf("second write: %v", err)
	}
	body, _ := os.ReadFile(p)
	if string(body) != "first" {
		t.Fatalf("body = %q, want %q", body, "first")
	}
}

// TestWriteIfAbsent_NilContent confirms nil-body produces a zero-byte
// file (not a broken write) — needed because writePlanScaffold seeds
// `_data_systems.yaml` with no content as an empty placeholder.
func TestWriteIfAbsent_NilContent(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "empty")
	if err := writeIfAbsent(p, nil); err != nil {
		t.Fatalf("write: %v", err)
	}
	info, err := os.Stat(p)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Size() != 0 {
		t.Fatalf("expected zero-byte file, got size=%d", info.Size())
	}
}

// TestWritePlanScaffold pins the on-disk wire format of `_config.lock`:
// trailing newline, JSON with the three default fields. Plan tooling
// (next-prefix, lint) reads these values, so a layout change here would
// silently miscalibrate every downstream command.
func TestWritePlanScaffold(t *testing.T) {
	dir := t.TempDir()
	if err := writePlanScaffold(dir); err != nil {
		t.Fatalf("writePlanScaffold: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, planDir, planSystemsFile)); err != nil {
		t.Fatalf("missing systems file: %v", err)
	}
	lockPath := filepath.Join(dir, planDir, planConfigLockFile)
	body, err := os.ReadFile(lockPath)
	if err != nil {
		t.Fatalf("read lock: %v", err)
	}
	if !strings.HasSuffix(string(body), "\n") {
		t.Fatalf("expected trailing newline in lock file")
	}
	var got struct {
		PrefixWidth   int    `json:"prefix_width"`
		MaxPlanLines  int    `json:"max_plan_lines"`
		PlanReviewPer string `json:"plan_review_per"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.PrefixWidth != defaultPrefixWidth ||
		got.MaxPlanLines != defaultMaxPlanLines ||
		got.PlanReviewPer != defaultPlanReviewPer {
		t.Fatalf("lock defaults wrong: %+v", got)
	}
}

// TestWritePlanScaffold_Idempotent is the lock-file semantics check:
// once a user has pinned values (Cargo.lock / package-lock.json
// analog), a subsequent `x-x init` must NOT refresh them. This is what
// keeps long-lived projects on their original prefix width / line caps.
func TestWritePlanScaffold_Idempotent(t *testing.T) {
	dir := t.TempDir()
	if err := writePlanScaffold(dir); err != nil {
		t.Fatalf("first: %v", err)
	}
	// Mutate the lock so we can verify re-run does not overwrite it.
	lockPath := filepath.Join(dir, planDir, planConfigLockFile)
	if err := os.WriteFile(lockPath, []byte("USER\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := writePlanScaffold(dir); err != nil {
		t.Fatalf("second: %v", err)
	}
	body, _ := os.ReadFile(lockPath)
	if string(body) != "USER\n" {
		t.Fatalf("lock was overwritten on re-run: %q", body)
	}
}

// TestInstallSkill_Copy is the Windows/project-scope strategy:
// useSymlink=false produces a real directory with the contents copied
// out, not a link. Covers the path the e2e suite exercises end-to-end.
func TestInstallSkill_Copy(t *testing.T) {
	pinHome(t)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	dest := filepath.Join(t.TempDir(), "out")
	if err := installSkill(src, dest, false); err != nil {
		t.Fatalf("installSkill: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, "a.txt")); err != nil {
		t.Fatalf("expected copied file: %v", err)
	}
}

// TestInstallSkill_Symlink is the user-scope POSIX strategy:
// useSymlink=true produces a symbolic link rather than a copy, so the
// `~/.x-x/agents/` refresh flow propagates to every project at once.
// Skipped on Windows where os.Symlink requires Developer Mode.
func TestInstallSkill_Symlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink path not used on Windows")
	}
	pinHome(t)
	src := t.TempDir()
	dest := filepath.Join(t.TempDir(), "link")
	if err := installSkill(src, dest, true); err != nil {
		t.Fatalf("installSkill: %v", err)
	}
	info, err := os.Lstat(dest)
	if err != nil {
		t.Fatalf("lstat: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("expected symlink, got mode %v", info.Mode())
	}
}

// TestInstallSkill_OverwritesExistingDir pins the "RemoveAll + recreate"
// semantics introduced after we ripped out the .x-x-managed marker:
// re-running init must replace any stale skill content cleanly without
// asking permission. Stale files MUST NOT survive.
func TestInstallSkill_OverwritesExistingDir(t *testing.T) {
	pinHome(t)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "new.txt"), []byte("new"), 0o600); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	dest := filepath.Join(t.TempDir(), "dest")
	if err := os.MkdirAll(dest, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dest, "stale.txt"), []byte("stale"), 0o600); err != nil {
		t.Fatalf("stale: %v", err)
	}
	if err := installSkill(src, dest, false); err != nil {
		t.Fatalf("installSkill: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, "stale.txt")); !os.IsNotExist(err) {
		t.Fatalf("stale.txt should be removed, err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, "new.txt")); err != nil {
		t.Fatalf("new.txt missing: %v", err)
	}
}

// TestCopyTree exercises the walk-based copy: nested directories must
// be created in the dest tree and a deep child file's bytes must survive
// the round-trip. Catches walk-ordering bugs that would surface as
// "no such file or directory" when a file is visited before its parent.
func TestCopyTree(t *testing.T) {
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "sub"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("A"), 0o600); err != nil {
		t.Fatalf("seed a: %v", err)
	}
	if err := os.WriteFile(filepath.Join(src, "sub", "b.txt"), []byte("B"), 0o600); err != nil {
		t.Fatalf("seed b: %v", err)
	}
	dest := filepath.Join(t.TempDir(), "out")
	if err := copyTree(src, dest); err != nil {
		t.Fatalf("copyTree: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dest, "sub", "b.txt"))
	if err != nil {
		t.Fatalf("read nested: %v", err)
	}
	if string(got) != "B" {
		t.Fatalf("got %q want B", got)
	}
}

// TestCopyFile exercises the byte-for-byte file copier with a nested
// dest path — the function must MkdirAll the parent itself rather than
// relying on the caller. Also pins the content equality so a buffered-
// write bug couldn't truncate.
func TestCopyFile(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	if err := os.WriteFile(src, []byte("payload"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	dest := filepath.Join(dir, "nested", "dest")
	if err := copyFile(src, dest); err != nil {
		t.Fatalf("copyFile: %v", err)
	}
	got, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != "payload" {
		t.Fatalf("got %q want payload", got)
	}
}

// TestCopyFile_MissingSource confirms a missing source surfaces an
// error rather than silently producing an empty dest — the same
// fail-loud contract that ensureBundledAgents' embed-side enforces.
func TestCopyFile_MissingSource(t *testing.T) {
	dir := t.TempDir()
	if err := copyFile(filepath.Join(dir, "nope"), filepath.Join(dir, "dest")); err == nil {
		t.Fatal("expected error for missing src")
	}
}

// TestInstallAgentConfig_SkipsExistingFile is the user-preservation
// rule for agent config: a pre-existing settings.json MUST keep its
// content (often hand-edited) when init re-runs. This is the explicit
// divergence from skill dirs which are always overwritten.
func TestInstallAgentConfig_SkipsExistingFile(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "settings.json"), []byte("FROM_BUNDLE"), 0o600); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	dest := t.TempDir()
	user := filepath.Join(dest, "settings.json")
	if err := os.WriteFile(user, []byte("USER_EDIT"), 0o600); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := installAgentConfig(src, dest, false); err != nil {
		t.Fatalf("install: %v", err)
	}
	got, _ := os.ReadFile(user)
	if string(got) != "USER_EDIT" {
		t.Fatalf("user edit clobbered: %q", got)
	}
}

// TestInstallAgentConfig_CopiesMissingFile is the inverse: when the
// dest doesn't already exist, init MUST seed the bundle's defaults. A
// fresh project should get the canned settings.json out of the box.
func TestInstallAgentConfig_CopiesMissingFile(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "settings.json"), []byte("FROM_BUNDLE"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	dest := filepath.Join(t.TempDir(), "dest")
	if err := installAgentConfig(src, dest, false); err != nil {
		t.Fatalf("install: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dest, "settings.json"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != "FROM_BUNDLE" {
		t.Fatalf("got %q want FROM_BUNDLE", got)
	}
}

// TestInstallAgentConfig_NestedFile covers the recursive case: nested
// agent-config files (e.g. agents/codex/sessions/*.json hypothetically)
// must land at the equivalent nested dest path. Pins the walk shape so
// future per-agent subdirs work without code changes.
func TestInstallAgentConfig_NestedFile(t *testing.T) {
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "nested"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(src, "nested", "f"), []byte("X"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	dest := filepath.Join(t.TempDir(), "dest")
	if err := installAgentConfig(src, dest, false); err != nil {
		t.Fatalf("install: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, "nested", "f")); err != nil {
		t.Fatalf("nested file missing: %v", err)
	}
}

// TestRunInit_ProjectScope_EndToEnd exercises the full project-scope
// init from a fresh empty dir: every bundled skill lands under each
// agent target's skills subdir, plus the .x-plan/ scaffold is seeded.
// This is the broadest integration test in the unit suite.
func TestRunInit_ProjectScope_EndToEnd(t *testing.T) {
	pinHome(t)
	projectDir := t.TempDir()
	chdir(t, projectDir)
	runInit([]string{"--scope", "project"})

	// Bundled skills must land under every agent target's skillsRel. Source
	// the destinations from the registry to honor the "no inline path
	// literals" rule from AGENTS.md.
	for _, target := range agentTargets {
		for _, name := range ownedSkills {
			p := filepath.Join(projectDir, target.skillsRel, name)
			if _, err := os.Stat(p); err != nil {
				t.Fatalf("missing %s: %v", p, err)
			}
		}
	}
	// Plan scaffold seeded.
	if _, err := os.Stat(filepath.Join(projectDir, planDir, planConfigLockFile)); err != nil {
		t.Fatalf("missing lock: %v", err)
	}
	if _, err := os.Stat(filepath.Join(projectDir, planDir, planSystemsFile)); err != nil {
		t.Fatalf("missing systems file: %v", err)
	}
}

// TestRunInit_AgentsFilter_OnlyInstallsSelected verifies the --agents
// flag actually skips the unchosen agents. Asserts on the AGENT'S
// install destinations being absent (not just the skill dirs) — proves
// installForTarget was never called for the unselected row.
func TestRunInit_AgentsFilter_OnlyInstallsSelected(t *testing.T) {
	pinHome(t)
	projectDir := t.TempDir()
	chdir(t, projectDir)
	// --agents claude → only the Claude target gets installed; Codex's
	// .agents/skills tree must NOT be touched.
	runInit([]string{"--scope", "project", "--agents", "claude"})

	// Source the install destinations from the registry, not hard-coded
	// path literals — same single-source-of-truth rule the rest of the
	// codebase follows. agentTargets[0] is Claude, [1] is Codex.
	claudeSkills := agentTargets[0].skillsRel
	codexSkills := agentTargets[1].skillsRel
	codexConfig := agentTargets[1].configRel
	for _, name := range ownedSkills {
		p := filepath.Join(projectDir, claudeSkills, name)
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("missing claude skill %s: %v", p, err)
		}
	}
	if _, err := os.Stat(filepath.Join(projectDir, codexSkills)); !os.IsNotExist(err) {
		t.Fatalf("%s should NOT exist when --agents=claude; err=%v", codexSkills, err)
	}
	if _, err := os.Stat(filepath.Join(projectDir, codexConfig)); !os.IsNotExist(err) {
		t.Fatalf("%s should NOT exist when --agents=claude; err=%v", codexConfig, err)
	}
}

// TestRunInit_UserScope_EndToEnd is the user-scope counterpart to the
// project-scope integration test. Crucially, on POSIX it asserts the
// install entries are SYMLINKS, not copies — the strategy difference is
// the whole point of supporting two scopes.
func TestRunInit_UserScope_EndToEnd(t *testing.T) {
	home := pinHome(t)
	chdir(t, t.TempDir())
	runInit([]string{"--scope", "user"})

	// User-scope on POSIX uses symlinks; on Windows it falls back to copy.
	// Walk the registry rather than hard-coding the per-agent skill dirs.
	for _, target := range agentTargets {
		for _, name := range ownedSkills {
			p := filepath.Join(home, target.skillsRel, name)
			info, err := os.Lstat(p)
			if err != nil {
				t.Fatalf("missing %s: %v", p, err)
			}
			if runtime.GOOS != "windows" {
				if info.Mode()&os.ModeSymlink == 0 {
					t.Fatalf("expected symlink at %s, got mode %v", p, info.Mode())
				}
			}
		}
	}
}

// TestRunInit_InteractivePrompt drives the real stdin path: substitutes
// os.Stdin with a pipe carrying "\n1\n" (default agents, then project
// scope). Two reads must succeed off the same buffered reader — proves
// the shared-bufio.Reader fix from the multi-prompt refactor is intact.
func TestRunInit_InteractivePrompt(t *testing.T) {
	pinHome(t)
	projectDir := t.TempDir()
	chdir(t, projectDir)

	// Substitute os.Stdin so promptAgents reads "\n" (default = all) and
	// then promptScope reads "1\n" (project). Order matters — runInit
	// asks WHAT before WHERE.
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	if _, err := w.WriteString("\n1\n"); err != nil {
		t.Fatalf("write pipe: %v", err)
	}
	_ = w.Close()
	origStdin := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = origStdin })

	runInit(nil)
	if _, err := os.Stat(filepath.Join(projectDir, planDir, planConfigLockFile)); err != nil {
		t.Fatalf("interactive init didn't seed plan scaffold: %v", err)
	}
}
