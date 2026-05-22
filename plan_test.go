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

// TestPrintPlanUsage guards the `x-x plan` help surface — every
// subcommand row must appear, so adding a new one without updating
// printPlanUsage fails the test.
func TestPrintPlanUsage(t *testing.T) {
	var buf bytes.Buffer
	printPlanUsage(&buf)
	out := buf.String()
	for _, want := range []string{
		"Usage: x-x plan <subcommand>",
		"next-prefix",
		"list",
		"lint",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("usage missing %q in %q", want, out)
		}
	}
}

// TestLoadPrefixWidth_MissingLockReturnsDefault: pre-init projects
// (no lock file yet) must fall back to defaultPrefixWidth so
// next-prefix works before scaffold setup.
func TestLoadPrefixWidth_MissingLockReturnsDefault(t *testing.T) {
	dir := t.TempDir()
	if got := loadPrefixWidth(dir); got != defaultPrefixWidth {
		t.Fatalf("got %d, want %d", got, defaultPrefixWidth)
	}
}

// TestLoadPrefixWidth_ValidLock confirms a well-formed lock file with
// `prefix_width` overrides the default — this is the whole point of
// the lock file (per-project pin).
func TestLoadPrefixWidth_ValidLock(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, planConfigLockFile),
		[]byte(`{"prefix_width":7}`), 0o600); err != nil {
		t.Fatalf("seed lock: %v", err)
	}
	if got := loadPrefixWidth(dir); got != 7 {
		t.Fatalf("got %d, want 7", got)
	}
}

// TestLoadPrefixWidth_MalformedJSONReturnsDefault is the
// hand-corrupted lock case — a user editing the file with `vim` and
// breaking the JSON shouldn't lock them out of `plan next-prefix`.
// Fail gracefully to the default, don't surface the parse error.
func TestLoadPrefixWidth_MalformedJSONReturnsDefault(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, planConfigLockFile),
		[]byte(`{not json`), 0o600); err != nil {
		t.Fatalf("seed lock: %v", err)
	}
	if got := loadPrefixWidth(dir); got != defaultPrefixWidth {
		t.Fatalf("got %d, want %d", got, defaultPrefixWidth)
	}
}

// TestLoadPrefixWidth_NonPositiveReturnsDefault rejects 0 (or any
// non-positive value) — a zero width would make every plan file start
// with empty prefix, which next-prefix can't render sensibly.
func TestLoadPrefixWidth_NonPositiveReturnsDefault(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, planConfigLockFile),
		[]byte(`{"prefix_width":0}`), 0o600); err != nil {
		t.Fatalf("seed lock: %v", err)
	}
	if got := loadPrefixWidth(dir); got != defaultPrefixWidth {
		t.Fatalf("got %d, want %d", got, defaultPrefixWidth)
	}
}

// TestScanHighestPrefix_MissingDirReturnsZero: missing planDir is
// treated as "no plans yet" → scan returns 0 → next-prefix returns 1.
// This is what makes `x-x plan next-prefix` safe on a fresh project.
func TestScanHighestPrefix_MissingDirReturnsZero(t *testing.T) {
	if got := scanHighestPrefix(filepath.Join(t.TempDir(), "absent"), 5); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
}

// TestScanHighestPrefix_EmptyDirReturnsZero is the inverse-population
// case: dir exists but contains no plans. Same expected result as the
// missing-dir case — both flow through next-prefix=1.
func TestScanHighestPrefix_EmptyDirReturnsZero(t *testing.T) {
	if got := scanHighestPrefix(t.TempDir(), 5); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
}

// TestScanHighestPrefix_PopulatedDir pins the "max prefix wins"
// semantics regardless of file-system listing order. Three plans
// seeded in non-sorted order; result must still be the highest number.
func TestScanHighestPrefix_PopulatedDir(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{fixturePlanName, "00003-bar.md", "00002-baz.md"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	if got := scanHighestPrefix(dir, 5); got != 3 {
		t.Fatalf("got %d, want 3", got)
	}
}

// TestScanHighestPrefix_IgnoresNonNumericPrefixes asserts the scan
// only consults files whose prefix matches the configured width — a
// stray README, the lock file itself, or a too-short prefix must not
// shift next-prefix.
func TestScanHighestPrefix_IgnoresNonNumericPrefixes(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{
		"00002-foo" + planFileExt,
		"README" + planFileExt,
		planConfigLockFile,
		"123-too-short" + planFileExt,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	if got := scanHighestPrefix(dir, 5); got != 2 {
		t.Fatalf("got %d, want 2 (only 5-digit prefix counted)", got)
	}
}

// TestScanHighestPrefix_RespectsCustomWidth proves the function uses
// the width argument (not a baked-in 5) to derive the digit-count
// regex — projects with width=7 pinned via _config.lock must work.
func TestScanHighestPrefix_RespectsCustomWidth(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "0000042-wide.md"), nil, 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if got := scanHighestPrefix(dir, 7); got != 42 {
		t.Fatalf("got %d, want 42", got)
	}
}

// ---------- plan list ----------

// TestStringSliceFlag_AppendsAndSplits pins the dual semantics: each
// `--<flag> X` call appends, and X is itself comma-split with
// whitespace trimming. The flag.Var-driven --agents and --status / --system
// flags all rely on this exact shape.
func TestStringSliceFlag_AppendsAndSplits(t *testing.T) {
	var s stringSliceFlag
	if err := s.Set("a"); err != nil {
		t.Fatalf("set a: %v", err)
	}
	if err := s.Set("b,c"); err != nil {
		t.Fatalf("set b,c: %v", err)
	}
	if err := s.Set("  ,d , "); err != nil {
		t.Fatalf("set ws: %v", err)
	}
	got := []string(s)
	want := []string{"a", "b", "c", "d"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got %v want %v", got, want)
	}
	if s.String() != "a,b,c,d" {
		t.Fatalf("String() = %q want a,b,c,d", s.String())
	}
}

// TestToFilterSet covers both the nil-input shortcut (returns nil to
// signal "no filter") and the populated-set membership shape used by
// the --status / --system filters in `plan list`.
func TestToFilterSet(t *testing.T) {
	if toFilterSet(nil) != nil {
		t.Fatal("nil input must produce nil set")
	}
	got := toFilterSet([]string{"x", "y"})
	if !got["x"] || !got["y"] || got["z"] {
		t.Fatalf("membership wrong: %v", got)
	}
}

// TestAnySystemMatches pins the OR semantics of --system: a plan
// matches if ANY of its declared systems is in the requested set. An
// AND interpretation would be a much narrower filter — easy regression.
func TestAnySystemMatches(t *testing.T) {
	needles := map[string]bool{"Auth": true}
	if !anySystemMatches([]string{"Other", "Auth"}, needles) {
		t.Fatal("expected match")
	}
	if anySystemMatches([]string{"Other"}, needles) {
		t.Fatal("unexpected match")
	}
	if anySystemMatches(nil, needles) {
		t.Fatal("empty haystack must not match")
	}
}

// TestParseInlineSystems is the lone parser test for the inline
// `systems: [a, b, "c"]` body — covers comma-split, whitespace
// trim, quote-strip (single AND double), empty-token skip, and
// the single-entry edge case.
func TestParseInlineSystems(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"Auth, Billing", []string{"Auth", "Billing"}},
		{`"Auth", 'Billing Service'`, []string{"Auth", "Billing Service"}},
		{"  Auth  ,  ,  Billing", []string{"Auth", "Billing"}},
		{"", nil},
		{"Single", []string{"Single"}},
	}
	for _, c := range cases {
		got := parseInlineSystems(c.in)
		if strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Fatalf("in=%q got %v want %v", c.in, got, c.want)
		}
	}
}

// writePlanFile is a test helper that writes a plan-shaped file with the
// given frontmatter body and (optional) body content.
func writePlanFile(t *testing.T, dir, name, fm, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	content := "---\n" + fm + "\n---\n" + body
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("seed %s: %v", name, err)
	}
	return path
}

// TestParsePlan_HappyPath is the round-trip for a well-formed plan:
// slug derives from the filename, status and inline systems come out
// of frontmatter, and NO warning fires for clean input.
func TestParsePlan_HappyPath(t *testing.T) {
	dir := t.TempDir()
	path := writePlanFile(t, dir, fixturePlanName,
		"status: valid\nsystems: [Auth, Billing]", "## Goal\n")
	var warn bytes.Buffer
	row, ok := parsePlan(path, &warn)
	if !ok {
		t.Fatalf("expected ok; warn=%q", warn.String())
	}
	if row.slug != "00001-foo" || row.status != "valid" ||
		strings.Join(row.systems, "|") != "Auth|Billing" {
		t.Fatalf("row = %+v", row)
	}
	if warn.Len() != 0 {
		t.Fatalf("unexpected warning: %q", warn.String())
	}
}

// TestParsePlan_NoFrontmatter: a file without a leading `---` fence is
// skipped with a "no frontmatter" warning. parsePlan must not return
// a partially-populated row for an invalid file.
func TestParsePlan_NoFrontmatter(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, fixturePlanName)
	if err := os.WriteFile(path, []byte("just body\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	var warn bytes.Buffer
	if _, ok := parsePlan(path, &warn); ok {
		t.Fatal("expected skip")
	}
	if !strings.Contains(warn.String(), "no frontmatter") {
		t.Fatalf("warn = %q", warn.String())
	}
}

// TestParsePlan_UnterminatedFrontmatter: opening fence with no closing
// `---` is rejected. Without this guard, parsePlan would silently consume
// the entire file as frontmatter and produce nonsense rows.
func TestParsePlan_UnterminatedFrontmatter(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, fixturePlanName)
	if err := os.WriteFile(path, []byte("---\nstatus: valid\nsystems: [A]\nbody\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	var warn bytes.Buffer
	if _, ok := parsePlan(path, &warn); ok {
		t.Fatal("expected skip")
	}
	if !strings.Contains(warn.String(), "unterminated") {
		t.Fatalf("warn = %q", warn.String())
	}
}

// TestParsePlan_MissingStatus: frontmatter present but no `status:` —
// rejected. status is required; absent it, `plan list` has no third
// column to print and downstream filters would crash.
func TestParsePlan_MissingStatus(t *testing.T) {
	dir := t.TempDir()
	path := writePlanFile(t, dir, fixturePlanName, "systems: [A]", "")
	var warn bytes.Buffer
	if _, ok := parsePlan(path, &warn); ok {
		t.Fatal("expected skip")
	}
	if !strings.Contains(warn.String(), "`status:`") {
		t.Fatalf("warn = %q", warn.String())
	}
}

// TestParsePlan_MissingSystems: frontmatter without `systems:` is
// rejected too. systems is the load-bearing field — both `plan list`'s
// --system filter and `plan lint`'s registry check depend on it.
func TestParsePlan_MissingSystems(t *testing.T) {
	dir := t.TempDir()
	path := writePlanFile(t, dir, fixturePlanName, "status: valid", "")
	var warn bytes.Buffer
	if _, ok := parsePlan(path, &warn); ok {
		t.Fatal("expected skip")
	}
	if !strings.Contains(warn.String(), "`systems:`") {
		t.Fatalf("warn = %q", warn.String())
	}
}

func TestParsePlan_RejectsBlockSystems(t *testing.T) {
	// Block-form `systems:\n  - Auth` is intentionally NOT supported —
	// only inline arrays are recognized (matches the Python contract).
	dir := t.TempDir()
	path := writePlanFile(t, dir, fixturePlanName,
		"status: valid\nsystems:\n  - Auth", "")
	var warn bytes.Buffer
	if _, ok := parsePlan(path, &warn); ok {
		t.Fatal("block-form systems must be rejected")
	}
}

// TestListPlans_MissingDirIsEmpty: missing planDir → empty slice, no
// error. The CLI gate (requireProject) catches genuine missing-project
// states, so the inner helper just needs graceful no-data behavior.
func TestListPlans_MissingDirIsEmpty(t *testing.T) {
	var warn bytes.Buffer
	rows, err := listPlans(filepath.Join(t.TempDir(), "absent"), 5, &warn)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected empty, got %v", rows)
	}
}

// TestListPlans_EmptyDir: dir exists, no plans yet — must return
// empty + nil error rather than treating "0 plans" as a failure.
func TestListPlans_EmptyDir(t *testing.T) {
	var warn bytes.Buffer
	rows, err := listPlans(t.TempDir(), 5, &warn)
	if err != nil || len(rows) != 0 {
		t.Fatalf("err=%v rows=%v", err, rows)
	}
}

// TestListPlans_SortsByPrefix is the output-ordering contract: rows
// must come back in zero-padded prefix order (which equals numerical
// order). Seeded out-of-order on purpose to catch a regression where
// readdir order leaked through.
func TestListPlans_SortsByPrefix(t *testing.T) {
	dir := t.TempDir()
	writePlanFile(t, dir, "00003-charlie.md", "status: valid\nsystems: [C]", "")
	writePlanFile(t, dir, "00001-alpha.md", "status: valid\nsystems: [A]", "")
	writePlanFile(t, dir, "00002-bravo.md", "status: deprecated\nsystems: [B]", "")
	var warn bytes.Buffer
	rows, err := listPlans(dir, 5, &warn)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	slugs := make([]string, len(rows))
	for i, r := range rows {
		slugs[i] = r.slug
	}
	want := "00001-alpha|00002-bravo|00003-charlie"
	if strings.Join(slugs, "|") != want {
		t.Fatalf("got %q want %q", strings.Join(slugs, "|"), want)
	}
}

// TestListPlans_IgnoresNonMatchingNames: filename-pattern filter
// silently drops stray files (README, short prefix, no .md extension,
// dir-named-like-file). No warning, because these aren't user-visible
// "broken plans" — they're just noise that happens to share the dir.
func TestListPlans_IgnoresNonMatchingNames(t *testing.T) {
	dir := t.TempDir()
	writePlanFile(t, dir, "00001-real.md", "status: valid\nsystems: [A]", "")
	// All of these must be skipped — wrong width, no slug, no .md, or
	// not a regular file.
	if err := os.WriteFile(filepath.Join(dir, "README.md"), nil, 0o600); err != nil {
		t.Fatalf("seed README: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "123-too-short.md"), nil, 0o600); err != nil {
		t.Fatalf("seed short: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "00002-no-extension"), nil, 0o600); err != nil {
		t.Fatalf("seed no-ext: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "00099-a-dir.md"), 0o700); err != nil {
		t.Fatalf("seed dir: %v", err)
	}
	var warn bytes.Buffer
	rows, err := listPlans(dir, 5, &warn)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(rows) != 1 || rows[0].slug != "00001-real" {
		t.Fatalf("rows = %v", rows)
	}
	if warn.Len() != 0 {
		t.Fatalf("non-matching names should not warn: %q", warn.String())
	}
}

func TestListPlans_WarnsOnMatchingButMalformedFile(t *testing.T) {
	dir := t.TempDir()
	// Filename matches the pattern, content does not have frontmatter →
	// warn + skip, but do not abort sibling parsing.
	if err := os.WriteFile(filepath.Join(dir, "00001-broken.md"),
		[]byte("nope\n"), 0o600); err != nil {
		t.Fatalf("seed broken: %v", err)
	}
	writePlanFile(t, dir, "00002-ok.md", "status: valid\nsystems: [A]", "")
	var warn bytes.Buffer
	rows, err := listPlans(dir, 5, &warn)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(rows) != 1 || rows[0].slug != "00002-ok" {
		t.Fatalf("rows = %v", rows)
	}
	if !strings.Contains(warn.String(), "00001-broken.md") {
		t.Fatalf("expected warning for broken file, got %q", warn.String())
	}
}

func TestListPlans_RespectsCustomWidth(t *testing.T) {
	dir := t.TempDir()
	writePlanFile(t, dir, "0000042-foo.md", "status: valid\nsystems: [A]", "")
	// 5-digit file must be ignored when width=7.
	writePlanFile(t, dir, "00001-bar.md", "status: valid\nsystems: [B]", "")
	var warn bytes.Buffer
	rows, err := listPlans(dir, 7, &warn)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(rows) != 1 || rows[0].slug != "0000042-foo" {
		t.Fatalf("rows = %v", rows)
	}
}

// ---------- plan lint ----------

func TestLoadMaxPlanLines_MissingLockReturnsDefault(t *testing.T) {
	if got := loadMaxPlanLines(t.TempDir()); got != defaultMaxPlanLines {
		t.Fatalf("got %d, want %d", got, defaultMaxPlanLines)
	}
}

func TestLoadMaxPlanLines_ValidLock(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, planConfigLockFile),
		[]byte(`{"max_plan_lines":17}`), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if got := loadMaxPlanLines(dir); got != 17 {
		t.Fatalf("got %d, want 17", got)
	}
}

func TestLoadMaxPlanLines_NonPositiveReturnsDefault(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, planConfigLockFile),
		[]byte(`{"max_plan_lines":0}`), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if got := loadMaxPlanLines(dir); got != defaultMaxPlanLines {
		t.Fatalf("got %d, want %d", got, defaultMaxPlanLines)
	}
}

func TestIsIndented(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"", false},
		{"foo", false},
		{" foo", true},
		{"\tfoo", true},
		{"- foo", false},
	}
	for _, c := range cases {
		if got := isIndented(c.in); got != c.want {
			t.Fatalf("isIndented(%q) = %v want %v", c.in, got, c.want)
		}
	}
}

func TestParseRegistryNames_MissingFileReturnsNil(t *testing.T) {
	if got := parseRegistryNames(filepath.Join(t.TempDir(), "absent")); got != nil {
		t.Fatalf("expected nil, got %v", got)
	}
}

func TestParseRegistryNames_HappyPath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, planSystemsFile)
	body := `# top comment
systems:
  - id: a
    name: Auth Service
    brief: handles auth
  - id: b
    name: "Billing Service"
    brief: handles billing

other:
  - id: c
    name: NotInSystems
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	got := parseRegistryNames(path)
	if !got["Auth Service"] || !got["Billing Service"] {
		t.Fatalf("missing expected names: %v", got)
	}
	if got["NotInSystems"] {
		t.Fatalf("entries outside the systems block must be ignored: %v", got)
	}
}

func TestSetDifference(t *testing.T) {
	a := map[string]bool{"x": true, "y": true, "z": true}
	b := map[string]bool{"y": true}
	got := setDifference(a, b)
	if strings.Join(got, ",") != "x,z" {
		t.Fatalf("got %v, want [x z]", got)
	}
	if len(setDifference(b, b)) != 0 {
		t.Fatal("expected empty diff")
	}
}

// validPlanFM is the canonical passing frontmatter+body used by lint tests.
// Defined once so per-failure cases can override one field at a time.
const (
	validPlanFM   = "status: valid\nsystems: [Auth Service]"
	validPlanBody = "## Goal\nDo a thing.\n\n## Approach\n- A\n\n## Tasks\n- [ ] The Auth Service shall do a thing.\n"
)

// fixturePlanName is the canonical plan filename used by every lint test
// case. Single source of truth so the extension (planFileExt) doesn't get
// duplicated as `fixturePlanName` across call sites — AGENTS.md hard rule.
var fixturePlanName = "00001-foo" + planFileExt

// fixtureRegistryPath is the .x-plan/_data_systems.yaml path passed to
// lintPlanFile as its `registryPath` arg. Composed from the constants so
// a rename of planDir or planSystemsFile lands in exactly one place.
var fixtureRegistryPath = filepath.Join(planDir, planSystemsFile)

func registryWith(names ...string) map[string]bool {
	m := make(map[string]bool, len(names))
	for _, n := range names {
		m[n] = true
	}
	return m
}

func TestLintPlanFile_HappyPath(t *testing.T) {
	dir := t.TempDir()
	path := writePlanFile(t, dir, fixturePlanName, validPlanFM, validPlanBody)
	findings := lintPlanFile(path, 5, 30, registryWith("Auth Service"),
		map[string]bool{"00001-foo": true}, fixtureRegistryPath)
	if len(findings) != 0 {
		t.Fatalf("expected no findings, got %v", findings)
	}
}

func TestLintPlanFile_BadFilename(t *testing.T) {
	dir := t.TempDir()
	path := writePlanFile(t, dir, "BAD-foo.md", validPlanFM, validPlanBody)
	findings := lintPlanFile(path, 5, 30, registryWith("Auth Service"),
		map[string]bool{}, fixtureRegistryPath)
	if !containsSubstr(findings, "filename") {
		t.Fatalf("expected filename finding, got %v", findings)
	}
}

func TestLintPlanFile_TooLong(t *testing.T) {
	dir := t.TempDir()
	bigBody := validPlanBody + strings.Repeat("x\n", 100)
	path := writePlanFile(t, dir, fixturePlanName, validPlanFM, bigBody)
	findings := lintPlanFile(path, 5, 30, registryWith("Auth Service"),
		map[string]bool{"00001-foo": true}, fixtureRegistryPath)
	if !containsSubstr(findings, "max is 30") {
		t.Fatalf("expected line-cap finding, got %v", findings)
	}
}

func TestLintPlanFile_NoFrontmatter(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, fixturePlanName)
	if err := os.WriteFile(path, []byte("just body\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	findings := lintPlanFile(path, 5, 30, registryWith("X"),
		map[string]bool{}, fixtureRegistryPath)
	if !containsSubstr(findings, "missing YAML frontmatter") {
		t.Fatalf("expected frontmatter finding, got %v", findings)
	}
}

func TestLintPlanFile_BadStatus(t *testing.T) {
	dir := t.TempDir()
	path := writePlanFile(t, dir, fixturePlanName,
		"status: bogus\nsystems: [Auth Service]", validPlanBody)
	findings := lintPlanFile(path, 5, 30, registryWith("Auth Service"),
		map[string]bool{"00001-foo": true}, fixtureRegistryPath)
	if !containsSubstr(findings, `status "bogus" is not one of`) {
		t.Fatalf("expected status finding, got %v", findings)
	}
}

func TestLintPlanFile_SystemNotInRegistry(t *testing.T) {
	dir := t.TempDir()
	path := writePlanFile(t, dir, fixturePlanName,
		"status: valid\nsystems: [Ghost]", "## Goal\n## Approach\n## Tasks\n- [ ] The Ghost shall haunt.\n")
	findings := lintPlanFile(path, 5, 30, registryWith("Auth Service"),
		map[string]bool{"00001-foo": true}, fixtureRegistryPath)
	if !containsSubstr(findings, `declared system "Ghost" is not in`) {
		t.Fatalf("expected registry finding, got %v", findings)
	}
}

func TestLintPlanFile_SupersedesMissingSibling(t *testing.T) {
	dir := t.TempDir()
	path := writePlanFile(t, dir, fixturePlanName,
		"status: valid\nsystems: [Auth Service]\nsupersedes: [00099-nope]", validPlanBody)
	findings := lintPlanFile(path, 5, 30, registryWith("Auth Service"),
		map[string]bool{"00001-foo": true}, fixtureRegistryPath)
	if !containsSubstr(findings, `supersedes "00099-nope"`) {
		t.Fatalf("expected supersedes finding, got %v", findings)
	}
}

func TestLintPlanFile_EARSSubjectMismatch(t *testing.T) {
	dir := t.TempDir()
	// systems declares Auth, task body names Billing — both violations should fire.
	body := "## Goal\n## Approach\n## Tasks\n- [ ] The Billing Service shall send invoices.\n"
	path := writePlanFile(t, dir, fixturePlanName,
		"status: valid\nsystems: [Auth Service]", body)
	findings := lintPlanFile(path, 5, 30, registryWith("Auth Service", "Billing Service"),
		map[string]bool{"00001-foo": true}, fixtureRegistryPath)
	if !containsSubstr(findings, "EARS tasks name systems not in `systems:`") {
		t.Fatalf("expected EARS-in-tasks finding, got %v", findings)
	}
	if !containsSubstr(findings, "`systems:` declares systems not used in any EARS task") {
		t.Fatalf("expected EARS-in-systems finding, got %v", findings)
	}
}

// containsSubstr reports whether any finding string contains substr.
func containsSubstr(findings []string, substr string) bool {
	for _, f := range findings {
		if strings.Contains(f, substr) {
			return true
		}
	}
	return false
}
