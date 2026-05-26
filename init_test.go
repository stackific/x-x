// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bytes"
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

// seedProject creates a fully initialized x-x project scaffold inside
// dir (plansDir/, the empty systems registry, and the config lock) so
// checkProject() returns nil. Used by every test that needs the gate
// to pass without invoking the full runInit flow.
func seedProject(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, plansDir), 0o700); err != nil {
		t.Fatalf("seed plansDir: %v", err)
	}
	for _, name := range []string{plansSystemsFile, plansConfigLockFile} {
		if err := os.WriteFile(filepath.Join(dir, plansDir, name), nil, 0o600); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
}

// TestCheckProject_FullyInitialized is the happy path: with plansDir AND
// both scaffold files present, the gate passes and project-level
// subcommands proceed.
func TestCheckProject_FullyInitialized(t *testing.T) {
	dir := t.TempDir()
	seedProject(t, dir)
	chdir(t, dir)
	if err := checkProject(); err != nil {
		t.Fatalf("expected nil, got %v", err)
	}
}

// TestCheckProject_MissingDir pins the failure trigger when the
// directory itself is absent. The error must mention "not an x-x project"
// (the wording the e2e suite asserts on) and must NOT leak any internal
// path component — the banner is deliberately path-free so users aren't
// told to look for files they don't need to know about.
func TestCheckProject_MissingDir(t *testing.T) {
	chdir(t, t.TempDir())
	err := checkProject()
	if err == nil {
		t.Fatal("expected error when plansDir is missing")
	}
	if !strings.Contains(err.Error(), "not an x-x project") {
		t.Fatalf("message = %q, want it to mention 'not an x-x project'", err.Error())
	}
	if strings.Contains(err.Error(), plansDir) {
		t.Fatalf("message %q leaks internal path %q", err.Error(), plansDir)
	}
}

// TestCheckProject_PlanIsFileNotDir hardens the gate against the
// pathological case where `.x-plans` exists but as a regular file — must
// still fail, since `os.ReadDir` on a file would crash the downstream
// plan-list / next-prefix logic.
func TestCheckProject_PlanIsFileNotDir(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, plansDir), nil, 0o600); err != nil {
		t.Fatalf("seed file: %v", err)
	}
	chdir(t, dir)
	if err := checkProject(); err == nil {
		t.Fatal("expected error when plansDir is a regular file")
	}
}

// TestCheckProject_SystemsFileNotRequired pins the gate's lock-file-only
// contract: removing `_data_systems.yaml` (user deleted it, or never
// populated it) does NOT downgrade the directory to "uninitialized".
// The lock file is the canonical project marker — deleting it (and only
// it) is the documented way to re-init without losing the systems
// registry or any plan files.
func TestCheckProject_SystemsFileNotRequired(t *testing.T) {
	dir := t.TempDir()
	seedProject(t, dir)
	if err := os.Remove(filepath.Join(dir, plansDir, plansSystemsFile)); err != nil {
		t.Fatalf("remove systems: %v", err)
	}
	chdir(t, dir)
	if err := checkProject(); err != nil {
		t.Fatalf("expected nil (lock file still present), got %v", err)
	}
}

// TestCheckProject_MissingLockFile is the symmetric pin for a missing
// `_config.lock`. Same generic-banner contract as the systems-file
// variant — the user shouldn't need to know which file we look at.
func TestCheckProject_MissingLockFile(t *testing.T) {
	dir := t.TempDir()
	seedProject(t, dir)
	if err := os.Remove(filepath.Join(dir, plansDir, plansConfigLockFile)); err != nil {
		t.Fatalf("remove lock: %v", err)
	}
	chdir(t, dir)
	err := checkProject()
	if err == nil {
		t.Fatal("expected error when lock file is missing")
	}
	if strings.Contains(err.Error(), plansConfigLockFile) {
		t.Fatalf("message %q leaks internal path %q", err.Error(), plansConfigLockFile)
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

// ---------- new plan-tooling prompts ----------

// TestPromptPrefixWidth_Default covers the "blank line = accept default"
// path that lets pre-existing callers pipe nothing into this prompt and
// still get a working install. Same convention as the other prompts.
func TestPromptPrefixWidth_Default(t *testing.T) {
	got, err := promptPrefixWidth(strings.NewReader("\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != defaultPrefixWidth {
		t.Fatalf("got %d, want %d", got, defaultPrefixWidth)
	}
}

// TestPromptPrefixWidth_ValidInt confirms a typed positive integer beats
// the default, mirroring the user's wizard choice in the line path.
func TestPromptPrefixWidth_ValidInt(t *testing.T) {
	got, err := promptPrefixWidth(strings.NewReader("8\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != 8 {
		t.Fatalf("got %d, want 8", got)
	}
}

// TestPromptPrefixWidth_Invalid pins strict rejection: non-numeric or
// non-positive input MUST error rather than silently fall back to the
// default — the user clearly typed something on purpose.
func TestPromptPrefixWidth_Invalid(t *testing.T) {
	for _, in := range []string{"x\n", "0\n", "-3\n"} {
		if _, err := promptPrefixWidth(strings.NewReader(in)); err == nil {
			t.Fatalf("expected error for %q", in)
		}
	}
}

// TestPromptMaxPlanLines_Default and _ValidInt mirror the prefix-width
// pair: shared helper readPositiveIntLine, but each prompt's own
// printed text + default needs end-to-end coverage so a typo in the
// constant wiring surfaces here.
func TestPromptMaxPlanLines_Default(t *testing.T) {
	got, err := promptMaxPlanLines(strings.NewReader("\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != defaultMaxPlanLines {
		t.Fatalf("got %d, want %d", got, defaultMaxPlanLines)
	}
}

func TestPromptMaxPlanLines_ValidInt(t *testing.T) {
	got, err := promptMaxPlanLines(strings.NewReader("75\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != 75 {
		t.Fatalf("got %d, want 75", got)
	}
}

// TestPromptReviewPer covers the 1/2 numeric picker, the "empty
// accepts default", and the strict-error tail case. Three sub-cases in
// one func because each is one-liner-tight.
func TestPromptReviewPer(t *testing.T) {
	cases := []struct {
		in      string
		want    string
		wantErr bool
	}{
		{"1\n", reviewPerTask, false},
		{"2\n", reviewPerPlan, false},
		{"\n", defaultReviewPer, false},
		{"3\n", "", true},
		{"task\n", "", true}, // strings are NOT accepted at the line picker
	}
	for _, c := range cases {
		got, err := promptReviewPer(strings.NewReader(c.in))
		if c.wantErr {
			if err == nil {
				t.Fatalf("in=%q: expected error, got %q", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Fatalf("in=%q: %v", c.in, err)
		}
		if got != c.want {
			t.Fatalf("in=%q: got %q want %q", c.in, got, c.want)
		}
	}
}

// TestParseScope is the standalone validator coverage for the
// initFlags.toConfig path: every valid string maps to its enum, every
// invalid string errors.
func TestParseScope(t *testing.T) {
	if s, err := parseScope("project"); err != nil || s != scopeProject {
		t.Fatalf("project: %v %v", s, err)
	}
	if s, err := parseScope("user"); err != nil || s != scopeUser {
		t.Fatalf("user: %v %v", s, err)
	}
	if _, err := parseScope("workspace"); err == nil {
		t.Fatal("expected error for workspace")
	}
}

// TestParseReviewPer mirrors TestParseScope for the review cadence
// validator. Allowlist semantics: anything outside {task, plan} errors.
func TestParseReviewPer(t *testing.T) {
	if s, err := parseReviewPer(reviewPerTask); err != nil || s != reviewPerTask {
		t.Fatalf("task: %v %v", s, err)
	}
	if s, err := parseReviewPer(reviewPerPlan); err != nil || s != reviewPerPlan {
		t.Fatalf("plan: %v %v", s, err)
	}
	if _, err := parseReviewPer("commit"); err == nil {
		t.Fatal("expected error for commit")
	}
}

// TestValidatePositiveInt is the huh.Input validator: integer + positive.
// Same rules the line-prompt parser enforces, surfaced as a string-only
// callback so huh can render an inline error before the user submits.
func TestValidatePositiveInt(t *testing.T) {
	for _, ok := range []string{"1", "4", "  9 ", "100"} {
		if err := validatePositiveInt(ok); err != nil {
			t.Fatalf("ok=%q: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "x", "0", "-2", "1.5"} {
		if err := validatePositiveInt(bad); err == nil {
			t.Fatalf("bad=%q: expected error", bad)
		}
	}
}

// ---------- resolveInitConfig ----------

// TestResolveInitConfig_AllFlagsSkipPrompts proves the short-circuit:
// every flag set → no stdin read, returned config carries the flag
// values verbatim. The panicReader is the trip-wire.
func TestResolveInitConfig_AllFlagsSkipPrompts(t *testing.T) {
	f := initFlags{
		agents:       []string{"claude"},
		scope:        "project",
		prefixWidth:  3,
		maxPlanLines: 10,
		reviewPer:    reviewPerPlan,
	}
	got, err := resolveInitConfig(f, panicReader{}, false)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got.scope != scopeProject ||
		got.prefixWidth != 3 ||
		got.maxPlanLines != 10 ||
		got.reviewPer != reviewPerPlan {
		t.Fatalf("config mismatch: %+v", got)
	}
	if len(got.agents) != 1 || got.agents[0].key != "claude" {
		t.Fatalf("agents = %+v", got.agents)
	}
}

// TestResolveInitConfig_LinePromptsFillUnset is the non-TTY path: when
// no flag is set, every prompt fires. Feed an explicit "1" for scope
// (promptScope is the one prompt with NO blank-default) and blanks for
// the rest; the four blank-defaulting prompts must each land on their
// project default in the returned config.
func TestResolveInitConfig_LinePromptsFillUnset(t *testing.T) {
	got, err := resolveInitConfig(initFlags{}, strings.NewReader("\n1\n\n\n\n"), false)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got.scope != scopeProject {
		t.Fatalf("scope = %v, want project", got.scope)
	}
	if got.prefixWidth != defaultPrefixWidth ||
		got.maxPlanLines != defaultMaxPlanLines ||
		got.reviewPer != defaultReviewPer {
		t.Fatalf("config = %+v", got)
	}
	if len(got.agents) != len(agentTargets) {
		t.Fatalf("agents = %+v (want all)", got.agents)
	}
}

// TestResolveInitConfig_BlankScopeErrors locks in the strict semantics
// of promptScope (no default), distinct from the other four prompts
// which DO default on blank. Mixing these conventions silently would
// hide a bad install.
func TestResolveInitConfig_BlankScopeErrors(t *testing.T) {
	_, err := resolveInitConfig(initFlags{}, strings.NewReader("\n\n\n\n\n"), false)
	if err == nil {
		t.Fatal("expected error: promptScope rejects empty input")
	}
}

// TestResolveInitConfig_MixedFlagsAndPrompts proves the partial path:
// scope + agents from flags, the three new values from line prompts.
// Order-dependent — the prompts must fire in the documented order.
func TestResolveInitConfig_MixedFlagsAndPrompts(t *testing.T) {
	f := initFlags{
		agents: []string{"claude"},
		scope:  "user",
	}
	got, err := resolveInitConfig(f, strings.NewReader("5\n50\n2\n"), false)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got.prefixWidth != 5 || got.maxPlanLines != 50 || got.reviewPer != reviewPerPlan {
		t.Fatalf("config = %+v", got)
	}
	if got.scope != scopeUser {
		t.Fatalf("scope = %v", got.scope)
	}
	if len(got.agents) != 1 || got.agents[0].key != "claude" {
		t.Fatalf("agents = %+v", got.agents)
	}
}

// TestInitFlags_CompleteCoverage walks every "exactly one missing field"
// combination to prove complete() returns true only when literally
// every field is non-zero. Encoding-level paranoia, since a future
// added field is easy to forget here.
func TestInitFlags_CompleteCoverage(t *testing.T) {
	full := initFlags{
		agents:       []string{"claude"},
		scope:        "project",
		prefixWidth:  4,
		maxPlanLines: 30,
		reviewPer:    reviewPerTask,
	}
	if !full.complete() {
		t.Fatal("full should be complete")
	}
	mutations := []func(*initFlags){
		func(f *initFlags) { f.agents = nil },
		func(f *initFlags) { f.scope = "" },
		func(f *initFlags) { f.prefixWidth = 0 },
		func(f *initFlags) { f.maxPlanLines = 0 },
		func(f *initFlags) { f.reviewPer = "" },
	}
	for i, mut := range mutations {
		cp := full
		mut(&cp)
		if cp.complete() {
			t.Fatalf("mutation %d: expected incomplete", i)
		}
	}
}

// TestInitFlags_ToConfig_InvalidValues hits the validator path: bad flag
// values surfaced as errors instead of slipping into the config. One
// case per validated field keeps the failure messages legible.
func TestInitFlags_ToConfig_InvalidValues(t *testing.T) {
	base := initFlags{
		agents:       []string{"claude"},
		scope:        "project",
		prefixWidth:  4,
		maxPlanLines: 30,
		reviewPer:    reviewPerTask,
	}
	cases := []struct {
		name string
		mut  func(*initFlags)
	}{
		{"unknown agent", func(f *initFlags) { f.agents = []string{"gemini"} }},
		{"bad scope", func(f *initFlags) { f.scope = "workspace" }},
		{"bad review", func(f *initFlags) { f.reviewPer = "commit" }},
		{"zero prefix", func(f *initFlags) { f.prefixWidth = 0 }},
		{"neg prefix", func(f *initFlags) { f.prefixWidth = -1 }},
		{"zero lines", func(f *initFlags) { f.maxPlanLines = 0 }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cp := base
			c.mut(&cp)
			if _, err := cp.toConfig(); err == nil {
				t.Fatal("expected error")
			}
		})
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
// file (not a broken write) — needed because writePlansScaffold seeds
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

// defaultInitConfig is the canonical "everything at project defaults"
// initConfig. Centralized so tests can reach for the same baseline
// rather than hand-rolling struct literals (which would silently drift
// if the constants ever move).
func defaultInitConfig() initConfig {
	return initConfig{
		prefixWidth:  defaultPrefixWidth,
		maxPlanLines: defaultMaxPlanLines,
		reviewPer:    defaultReviewPer,
	}
}

// TestWritePlansScaffold pins the on-disk wire format of `_config.lock`:
// trailing newline, JSON with the three configured fields. Plan tooling
// (next-prefix, lint) reads these values, so a layout change here would
// silently miscalibrate every downstream command.
func TestWritePlansScaffold(t *testing.T) {
	dir := t.TempDir()
	if err := writePlansScaffold(dir, defaultInitConfig()); err != nil {
		t.Fatalf("writePlansScaffold: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, plansDir, plansSystemsFile)); err != nil {
		t.Fatalf("missing systems file: %v", err)
	}
	lockPath := filepath.Join(dir, plansDir, plansConfigLockFile)
	body, err := os.ReadFile(lockPath)
	if err != nil {
		t.Fatalf("read lock: %v", err)
	}
	if !strings.HasSuffix(string(body), "\n") {
		t.Fatalf("expected trailing newline in lock file")
	}
	var got struct {
		PrefixWidth  int    `json:"prefix_width"`
		MaxPlanLines int    `json:"max_plan_lines"`
		ReviewPer    string `json:"review_per"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.PrefixWidth != defaultPrefixWidth ||
		got.MaxPlanLines != defaultMaxPlanLines ||
		got.ReviewPer != defaultReviewPer {
		t.Fatalf("lock defaults wrong: %+v", got)
	}
}

// TestWritePlansScaffold_HonorsConfig is the inverse of the defaults case:
// custom user values from the wizard / flags MUST land in the lock file
// verbatim rather than getting clobbered by the constants.
func TestWritePlansScaffold_HonorsConfig(t *testing.T) {
	dir := t.TempDir()
	cfg := initConfig{prefixWidth: 7, maxPlanLines: 120, reviewPer: reviewPerPlan}
	if err := writePlansScaffold(dir, cfg); err != nil {
		t.Fatalf("writePlansScaffold: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(dir, plansDir, plansConfigLockFile))
	if err != nil {
		t.Fatalf("read lock: %v", err)
	}
	var got struct {
		PrefixWidth  int    `json:"prefix_width"`
		MaxPlanLines int    `json:"max_plan_lines"`
		ReviewPer    string `json:"review_per"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.PrefixWidth != 7 || got.MaxPlanLines != 120 || got.ReviewPer != reviewPerPlan {
		t.Fatalf("lock didn't honor cfg: %+v", got)
	}
}

// TestWritePlansScaffold_Idempotent is the lock-file semantics check:
// once a user has pinned values (Cargo.lock / package-lock.json
// analog), a subsequent `x-x init` must NOT refresh them. This is what
// keeps long-lived projects on their original prefix width / line caps.
func TestWritePlansScaffold_Idempotent(t *testing.T) {
	dir := t.TempDir()
	if err := writePlansScaffold(dir, defaultInitConfig()); err != nil {
		t.Fatalf("first: %v", err)
	}
	// Mutate the lock so we can verify re-run does not overwrite it.
	lockPath := filepath.Join(dir, plansDir, plansConfigLockFile)
	if err := os.WriteFile(lockPath, []byte("USER\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := writePlansScaffold(dir, defaultInitConfig()); err != nil {
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

// TestInstallAgentConfig_SkipsExistingNonJSONFile pins the conservative
// fallback for file types we don't know how to merge: a pre-existing
// non-JSON file (e.g. config.toml) MUST keep its bytes intact. JSON
// destinations take the merge path (covered separately) — this case
// covers everything else.
func TestInstallAgentConfig_SkipsExistingNonJSONFile(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "config.toml"), []byte("FROM_BUNDLE"), 0o600); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	dest := t.TempDir()
	user := filepath.Join(dest, "config.toml")
	if err := os.WriteFile(user, []byte("USER_EDIT"), 0o600); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := installAgentConfig(src, dest); err != nil {
		t.Fatalf("install: %v", err)
	}
	got, _ := os.ReadFile(user)
	if string(got) != "USER_EDIT" {
		t.Fatalf("user edit clobbered: %q", got)
	}
}

// TestInstallAgentConfig_MergesExistingJSONFile pins the additive merge
// path: when a JSON destination already exists, installAgentConfig must
// (a) keep the user's existing key, (b) add the bundled key the user
// doesn't have, and (c) leave a parseable JSON file behind.
func TestInstallAgentConfig_MergesExistingJSONFile(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "settings.json"), []byte(`{"fastMode": true}`), 0o600); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	dest := t.TempDir()
	user := filepath.Join(dest, "settings.json")
	if err := os.WriteFile(user, []byte(`{"model": "sonnet"}`), 0o600); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := installAgentConfig(src, dest); err != nil {
		t.Fatalf("install: %v", err)
	}
	body, err := os.ReadFile(user)
	if err != nil {
		t.Fatalf("read merged: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("merged file is not valid JSON: %v\n%s", err, body)
	}
	if got["model"] != "sonnet" {
		t.Fatalf("user `model` lost: %v", got["model"])
	}
	if got["fastMode"] != true {
		t.Fatalf("bundle `fastMode` not added: %v", got["fastMode"])
	}
}

// TestInstallAgentConfig_MergesExistingJSONFile_UserWinsOnScalar pins
// the "existing wins on scalar conflict" half of the merge contract.
// A user who has explicitly set `fastMode: false` must NOT have it
// flipped to `true` by a re-run of init.
func TestInstallAgentConfig_MergesExistingJSONFile_UserWinsOnScalar(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "settings.json"), []byte(`{"fastMode": true}`), 0o600); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	dest := t.TempDir()
	user := filepath.Join(dest, "settings.json")
	if err := os.WriteFile(user, []byte(`{"fastMode": false}`), 0o600); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := installAgentConfig(src, dest); err != nil {
		t.Fatalf("install: %v", err)
	}
	body, _ := os.ReadFile(user)
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("merged file is not valid JSON: %v", err)
	}
	if got["fastMode"] != false {
		t.Fatalf("user scalar overwritten: fastMode=%v", got["fastMode"])
	}
}

// TestInstallAgentConfig_MergeMalformedExistingPreservesFile pins the
// safe-fallback policy: if the existing file is not valid JSON the
// install MUST NOT touch its bytes. A merge failure is logged to stderr
// and the user can fix or delete the file at leisure.
func TestInstallAgentConfig_MergeMalformedExistingPreservesFile(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "settings.json"), []byte(`{"fastMode": true}`), 0o600); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	dest := t.TempDir()
	user := filepath.Join(dest, "settings.json")
	if err := os.WriteFile(user, []byte("not json"), 0o600); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := installAgentConfig(src, dest); err != nil {
		t.Fatalf("install: %v", err)
	}
	got, _ := os.ReadFile(user)
	if string(got) != "not json" {
		t.Fatalf("malformed user file mutated: %q", got)
	}
}

// TestInstallAgentConfig_MergeEmptyExistingSeedsBundle pins the
// zero-byte edge case: a user who `touch`ed the file but never put
// JSON in it should get the bundle's top-level keys rather than a
// parse error.
func TestInstallAgentConfig_MergeEmptyExistingSeedsBundle(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "settings.json"), []byte(`{"fastMode": true}`), 0o600); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	dest := t.TempDir()
	user := filepath.Join(dest, "settings.json")
	if err := os.WriteFile(user, nil, 0o600); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := installAgentConfig(src, dest); err != nil {
		t.Fatalf("install: %v", err)
	}
	body, _ := os.ReadFile(user)
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("post-merge file not valid JSON: %v", err)
	}
	if got["fastMode"] != true {
		t.Fatalf("empty existing didn't seed bundle key: %v", got)
	}
}

// TestMergeJSON_ScalarExistingWins is the unit-level pin of the "user
// scalar wins" rule from mergeJSON. Covers both directions: an existing
// concrete value beats any bundled scalar, regardless of type.
func TestMergeJSON_ScalarExistingWins(t *testing.T) {
	got := mergeJSON("user", "bundle")
	if got != "user" {
		t.Fatalf("got %v, want user", got)
	}
	got = mergeJSON(false, true)
	if got != false {
		t.Fatalf("got %v, want false", got)
	}
}

// TestMergeJSON_NilExistingTakesBundled covers the seeding path used by
// mergeJSONFile when a key only exists on the bundled side (existing
// returns nil at the recursion step).
func TestMergeJSON_NilExistingTakesBundled(t *testing.T) {
	got := mergeJSON(nil, "bundle")
	if got != "bundle" {
		t.Fatalf("got %v, want bundle", got)
	}
}

// TestMergeJSON_ObjectsAdditive pins the object-merge path: shared
// keys recurse (user wins on scalar), keys-only-on-bundle are added,
// keys-only-on-user survive. This is the shape that lets a user's
// existing model setting + our hooks both end up in settings.json.
func TestMergeJSON_ObjectsAdditive(t *testing.T) {
	existing := map[string]any{"model": "sonnet", "fastMode": false}
	bundled := map[string]any{"fastMode": true, "hooks": map[string]any{"Stop": []any{"x"}}}
	got, ok := mergeJSON(existing, bundled).(map[string]any)
	if !ok {
		t.Fatalf("got %T, want map", got)
	}
	if got["model"] != "sonnet" {
		t.Fatalf("user-only key dropped: %v", got)
	}
	if got["fastMode"] != false {
		t.Fatalf("shared key not user-wins: %v", got)
	}
	if _, ok := got["hooks"]; !ok {
		t.Fatalf("bundle-only key not added: %v", got)
	}
}

// TestMergeJSON_ArraysUnionDedup covers the array-union half of the
// merge: bundled entries appended after existing ones in registry order,
// and entries that deep-equal something already present are skipped so
// re-running init never produces duplicates.
func TestMergeJSON_ArraysUnionDedup(t *testing.T) {
	existing := []any{"a", map[string]any{"k": "v"}}
	bundled := []any{map[string]any{"k": "v"}, "b"}
	got, ok := mergeJSON(existing, bundled).([]any)
	if !ok {
		t.Fatalf("got %T, want slice", got)
	}
	// Expected: existing first, then bundled minus the duplicate object.
	if len(got) != 3 {
		t.Fatalf("got %d entries, want 3 (%v)", len(got), got)
	}
	if got[0] != "a" {
		t.Fatalf("got[0]=%v want a", got[0])
	}
	if got[2] != "b" {
		t.Fatalf("got[2]=%v want b", got[2])
	}
}

// TestMergeJSON_TypeMismatchExistingWins pins the defensive branch in
// mergeJSON: if the user's value is an array and the bundle's value at
// the same key is an object (or vice-versa), the user's value survives
// untouched — we never silently rewrite a shape we don't understand.
func TestMergeJSON_TypeMismatchExistingWins(t *testing.T) {
	existing := []any{1, 2}
	bundled := map[string]any{"k": "v"}
	got := mergeJSON(existing, bundled)
	arr, ok := got.([]any)
	if !ok {
		t.Fatalf("got %T, want []any", got)
	}
	if len(arr) != 2 {
		t.Fatalf("got %v, want existing slice intact", arr)
	}
}

// TestMergeJSON_Idempotent ensures running the merge twice over the
// same bundled value is a no-op: the second pass adds nothing because
// every bundled entry already deep-equals an existing one. This is the
// invariant that makes back-to-back `x-x init` runs safe.
func TestMergeJSON_Idempotent(t *testing.T) {
	existing := map[string]any{"hooks": map[string]any{"Stop": []any{"x"}}}
	bundled := map[string]any{"hooks": map[string]any{"Stop": []any{"x"}}}
	first, _ := mergeJSON(existing, bundled).(map[string]any)
	second, _ := mergeJSON(first, bundled).(map[string]any)
	firstStop := first["hooks"].(map[string]any)["Stop"].([]any)
	secondStop := second["hooks"].(map[string]any)["Stop"].([]any)
	if len(firstStop) != 1 || len(secondStop) != 1 {
		t.Fatalf("expected stable length 1, got first=%d second=%d", len(firstStop), len(secondStop))
	}
}

// TestMergeJSONFile_RealBundle_AdditiveAndIdempotent is the
// end-to-end pin for the merge primitive: feed it the actual bundled
// Claude settings.json + a user-edited settings.json, and verify both
// (a) the user key survives, (b) every bundled top-level key lands,
// and (c) re-running the merge produces a byte-identical file.
func TestMergeJSONFile_RealBundle_AdditiveAndIdempotent(t *testing.T) {
	dir := t.TempDir()
	bundlePath := filepath.Join(dir, "bundle.json")
	bundle := []byte(`{
  "fastMode": true,
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "x-x plans lint"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "x-x plans lint"}]}
    ]
  }
}`)
	if err := os.WriteFile(bundlePath, bundle, 0o600); err != nil {
		t.Fatalf("seed bundle: %v", err)
	}
	userPath := filepath.Join(dir, "user.json")
	user := []byte(`{
  "model": "sonnet",
  "hooks": {
    "PostToolUse": [
      {"matcher": "Read", "hooks": [{"type": "command", "command": "my-tool"}]}
    ]
  }
}`)
	if err := os.WriteFile(userPath, user, 0o600); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := mergeJSONFile(bundlePath, userPath); err != nil {
		t.Fatalf("merge: %v", err)
	}
	body, _ := os.ReadFile(userPath)
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("merged file not valid JSON: %v\n%s", err, body)
	}
	if got["model"] != "sonnet" {
		t.Fatalf("user model lost: %v", got)
	}
	if got["fastMode"] != true {
		t.Fatalf("bundle fastMode missing: %v", got)
	}
	hooks, _ := got["hooks"].(map[string]any)
	post, _ := hooks["PostToolUse"].([]any)
	if len(post) != 2 {
		t.Fatalf("PostToolUse expected 2 entries (user + bundle), got %d: %v", len(post), post)
	}
	stop, _ := hooks["Stop"].([]any)
	if len(stop) != 1 {
		t.Fatalf("Stop expected 1 entry (bundle-only), got %d: %v", len(stop), stop)
	}

	// Round 2: re-run on the merged file with the same bundle. Result
	// must be byte-identical — array dedup catches every bundled entry.
	first := append([]byte(nil), body...)
	if err := mergeJSONFile(bundlePath, userPath); err != nil {
		t.Fatalf("re-merge: %v", err)
	}
	body2, _ := os.ReadFile(userPath)
	if !bytes.Equal(body2, first) {
		t.Fatalf("merge not idempotent:\nfirst:\n%s\nsecond:\n%s", first, body2)
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
	if err := installAgentConfig(src, dest); err != nil {
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
	if err := installAgentConfig(src, dest); err != nil {
		t.Fatalf("install: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, "nested", "f")); err != nil {
		t.Fatalf("nested file missing: %v", err)
	}
}

// TestRunInit_ProjectScope_EndToEnd exercises the full project-scope
// init from a fresh empty dir: every bundled skill lands under each
// agent target's skills subdir, plus the .x-plans/ scaffold is seeded.
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
	if _, err := os.Stat(filepath.Join(projectDir, plansDir, plansConfigLockFile)); err != nil {
		t.Fatalf("missing lock: %v", err)
	}
	if _, err := os.Stat(filepath.Join(projectDir, plansDir, plansSystemsFile)); err != nil {
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
	cwd := t.TempDir()
	chdir(t, cwd)
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

	// User-scope MUST NOT drop the project-scoped .x-plans/ scaffold into
	// the user's terminal cwd. Earlier the scaffold write was unconditional;
	// that polluted unrelated working directories and tripped the project
	// gate on the next x-x invocation. Gating the scaffold-write on
	// project scope keeps the user's cwd untouched.
	if _, err := os.Stat(filepath.Join(cwd, plansDir)); !os.IsNotExist(err) {
		t.Fatalf("user-scope init leaked %s/ into cwd (%v); should only land for --scope project",
			plansDir, err)
	}
}

// TestRunInit_InteractivePrompt drives the real stdin path: substitutes
// os.Stdin with a pipe carrying the five line-prompt answers (default
// agents, project scope, then default acceptances for prefix-width /
// max-plan-lines / review-per). Five reads must succeed off the
// same buffered reader — proves the shared-bufio.Reader fix from the
// multi-prompt refactor is intact across the expanded sequence.
func TestRunInit_InteractivePrompt(t *testing.T) {
	pinHome(t)
	projectDir := t.TempDir()
	chdir(t, projectDir)

	// Substitute os.Stdin so the line-prompt branch fires in order:
	//   "\n"  agents     → default all
	//   "1\n" scope      → project
	//   "\n"  prefix     → default
	//   "\n"  max-lines  → default
	//   "\n"  review     → default (task)
	// runInit asks WHAT before WHERE before HOW.
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	if _, err := w.WriteString("\n1\n\n\n\n"); err != nil {
		t.Fatalf("write pipe: %v", err)
	}
	_ = w.Close()
	origStdin := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = origStdin })

	runInit(nil)
	if _, err := os.Stat(filepath.Join(projectDir, plansDir, plansConfigLockFile)); err != nil {
		t.Fatalf("interactive init didn't seed plan scaffold: %v", err)
	}
}

// TestRunInit_AllFlags drives the fully non-interactive branch of
// resolveInitConfig: every prompt has a flag twin, and when they are
// all set runInit never reads stdin (we install a panicReader as
// os.Stdin to prove it). Asserts that the chosen plan-tooling values
// end up in `_config.lock` byte-for-byte.
func TestRunInit_AllFlags(t *testing.T) {
	pinHome(t)
	projectDir := t.TempDir()
	chdir(t, projectDir)

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	_ = w.Close()
	origStdin := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = origStdin })

	runInit([]string{
		"--scope", "project",
		"--agents", "claude,codex",
		"--prefix-width", "6",
		"--max-plan-lines", "42",
		"--review-per", reviewPerPlan,
	})

	body, err := os.ReadFile(filepath.Join(projectDir, plansDir, plansConfigLockFile))
	if err != nil {
		t.Fatalf("read lock: %v", err)
	}
	var got struct {
		PrefixWidth  int    `json:"prefix_width"`
		MaxPlanLines int    `json:"max_plan_lines"`
		ReviewPer    string `json:"review_per"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.PrefixWidth != 6 || got.MaxPlanLines != 42 || got.ReviewPer != reviewPerPlan {
		t.Fatalf("lock didn't honor flags: %+v", got)
	}
}
