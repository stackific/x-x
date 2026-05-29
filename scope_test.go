// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPrintScopesUsage guards the `stax scopes` help surface — every
// subcommand row must appear, so adding a new one without updating
// printPlansUsage fails the test.
func TestPrintScopesUsage(t *testing.T) {
	var buf bytes.Buffer
	printPlansUsage(&buf)
	out := buf.String()
	for _, want := range []string{
		"Usage: stax scopes <subcommand>",
		"next-prefix",
		"list",
		"lint",
		"slugify",
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
	if err := os.WriteFile(filepath.Join(dir, staxLockFile),
		[]byte(`{"prefix_width":7}`), 0o600); err != nil {
		t.Fatalf("seed lock: %v", err)
	}
	if got := loadPrefixWidth(dir); got != 7 {
		t.Fatalf("got %d, want 7", got)
	}
}

// TestLoadPrefixWidth_MalformedJSONReturnsDefault is the
// hand-corrupted lock case — a user editing the file with `vim` and
// breaking the JSON shouldn't lock them out of `scope next-prefix`.
// Fail gracefully to the default, don't surface the parse error.
func TestLoadPrefixWidth_MalformedJSONReturnsDefault(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, staxLockFile),
		[]byte(`{not json`), 0o600); err != nil {
		t.Fatalf("seed lock: %v", err)
	}
	if got := loadPrefixWidth(dir); got != defaultPrefixWidth {
		t.Fatalf("got %d, want %d", got, defaultPrefixWidth)
	}
}

// TestLoadPrefixWidth_NonPositiveReturnsDefault rejects 0 (or any
// non-positive value) — a zero width would make every scope file start
// with empty prefix, which next-prefix can't render sensibly.
func TestLoadPrefixWidth_NonPositiveReturnsDefault(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, staxLockFile),
		[]byte(`{"prefix_width":0}`), 0o600); err != nil {
		t.Fatalf("seed lock: %v", err)
	}
	if got := loadPrefixWidth(dir); got != defaultPrefixWidth {
		t.Fatalf("got %d, want %d", got, defaultPrefixWidth)
	}
}

// TestScanHighestPrefix_MissingDirReturnsZero: missing staxDir is
// treated as "no scopes yet" → scan returns 0 → next-prefix returns 1.
// This is what makes `stax scopes next-prefix` safe on a fresh project.
func TestScanHighestPrefix_MissingDirReturnsZero(t *testing.T) {
	if got := scanHighestPrefix(filepath.Join(t.TempDir(), "absent"), 5); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
}

// TestScanHighestPrefix_EmptyDirReturnsZero is the inverse-population
// case: dir exists but contains no scopes. Same expected result as the
// missing-dir case — both flow through next-prefix=1.
func TestScanHighestPrefix_EmptyDirReturnsZero(t *testing.T) {
	if got := scanHighestPrefix(t.TempDir(), 5); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
}

// TestScanHighestPrefix_PopulatedDir pins the "max prefix wins"
// semantics regardless of file-system listing order. Three scopes
// seeded in non-sorted order; result must still be the highest number.
func TestScanHighestPrefix_PopulatedDir(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{fixtureScopeName, "00003-bar.md", "00002-baz.md"} {
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
		"00002-foo" + scopeFileExt,
		"README" + scopeFileExt,
		staxLockFile,
		"123-too-short" + scopeFileExt,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	if got := scanHighestPrefix(dir, 5); got != 2 {
		t.Fatalf("got %d, want 2 (only 5-digit prefix counted)", got)
	}
}

// TestScanHighestPrefix_IgnoresWiderPrefix locks in consistency with
// listScopes / lint: a file whose digit-prefix is WIDER than the
// configured width (5 digits when width=4) must not be counted. Earlier
// the scan used `^(\d{width})` which would greedily read the first
// `width` digits of `00099-extra.md` as prefix 9 — but listScopes / lint
// require `^\d{width}-` to recognize a scope file, so next-prefix would
// hand out numbers based on files list/lint silently ignore. Anchoring
// the scan on the trailing `-` and `.md` plugs that gap.
func TestScanHighestPrefix_IgnoresWiderPrefix(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{
		"0003-three" + scopeFileExt,   // 4-digit prefix, valid
		"00099-extra" + scopeFileExt,  // 5-digit prefix, invisible at width=4
		"00500-bigger" + scopeFileExt, // 5-digit prefix, invisible at width=4
	} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	if got := scanHighestPrefix(dir, 4); got != 3 {
		t.Fatalf("got %d, want 3 (5-digit prefixes must be ignored at width=4)", got)
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

// ---------- scope list ----------

// TestStringSliceFlag_AppendsAndSplits pins the dual semantics: each
// `--<flag> X` call appends, and X is itself comma-split with
// whitespace trimming. The flag.Var-driven --agents and --status / --system
// flags all rely on this exact form.
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
// signal "no filter") and the populated-set membership form used by
// the --status / --system filters in `scope list`.
func TestToFilterSet(t *testing.T) {
	if toFilterSet(nil) != nil {
		t.Fatal("nil input must produce nil set")
	}
	got := toFilterSet([]string{"x", "y"})
	if !got["x"] || !got["y"] || got["z"] {
		t.Fatalf("membership wrong: %v", got)
	}
}

// TestAnySystemMatches pins the OR semantics of --system: a scope
// matches if ANY of its declared system ids is in the requested set. An
// AND interpretation would be a much narrower filter — easy regression.
// Both sides are kebab-case ids (the frontmatter `systems:` array and the
// `--system <id>` flag), so the matcher is a plain string-set check.
func TestAnySystemMatches(t *testing.T) {
	needles := map[string]bool{"auth": true}
	if !anySystemMatches([]string{"other", "auth"}, needles) {
		t.Fatal("expected match")
	}
	if anySystemMatches([]string{"other"}, needles) {
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

// writeScopeFile is a test helper that writes a scope-format file with the
// given frontmatter body and (optional) body content.
func writeScopeFile(t *testing.T, dir, name, fm, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	content := "---\n" + fm + "\n---\n" + body
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("seed %s: %v", name, err)
	}
	return path
}

// TestParseScope_HappyPath is the round-trip for a well-formed scope:
// slug derives from the filename, status and inline systems come out
// of frontmatter, and NO warning fires for clean input.
func TestParseScope_HappyPath(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"status: valid\nsystems: [Auth, Billing]", "## Goal\n")
	var warn bytes.Buffer
	row, ok := parseScopeFile(path, &warn)
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

// TestParseScope_NoFrontmatter: a file without a leading `---` fence is
// skipped with a "no frontmatter" warning. parseScopeFile must not return
// a partially-populated row for an invalid file.
func TestParseScope_NoFrontmatter(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, fixtureScopeName)
	if err := os.WriteFile(path, []byte("just body\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	var warn bytes.Buffer
	if _, ok := parseScopeFile(path, &warn); ok {
		t.Fatal("expected skip")
	}
	if !strings.Contains(warn.String(), "no frontmatter") {
		t.Fatalf("warn = %q", warn.String())
	}
}

// TestParseScope_UnterminatedFrontmatter: opening fence with no closing
// `---` is rejected. Without this guard, parseScopeFile would silently consume
// the entire file as frontmatter and produce nonsense rows.
func TestParseScope_UnterminatedFrontmatter(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, fixtureScopeName)
	if err := os.WriteFile(path, []byte("---\nstatus: valid\nsystems: [A]\nbody\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	var warn bytes.Buffer
	if _, ok := parseScopeFile(path, &warn); ok {
		t.Fatal("expected skip")
	}
	if !strings.Contains(warn.String(), "unterminated") {
		t.Fatalf("warn = %q", warn.String())
	}
}

// TestParseScope_MissingStatus: frontmatter present but no `status:` —
// rejected. status is required; absent it, `scope list` has no third
// column to print and downstream filters would crash.
func TestParseScope_MissingStatus(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName, "systems: [A]", "")
	var warn bytes.Buffer
	if _, ok := parseScopeFile(path, &warn); ok {
		t.Fatal("expected skip")
	}
	if !strings.Contains(warn.String(), "`status:`") {
		t.Fatalf("warn = %q", warn.String())
	}
}

// TestParseScope_MissingSystems: frontmatter without `systems:` is
// rejected too. systems is the critical field — both `scope list`'s
// --system filter and `scope lint`'s registry check depend on it.
func TestParseScope_MissingSystems(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName, "status: valid", "")
	var warn bytes.Buffer
	if _, ok := parseScopeFile(path, &warn); ok {
		t.Fatal("expected skip")
	}
	if !strings.Contains(warn.String(), "`systems:`") {
		t.Fatalf("warn = %q", warn.String())
	}
}

func TestParseScope_RejectsBlockSystems(t *testing.T) {
	// Block-form `systems:\n  - Auth` is intentionally NOT supported —
	// only inline arrays are recognized.
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"status: valid\nsystems:\n  - Auth", "")
	var warn bytes.Buffer
	if _, ok := parseScopeFile(path, &warn); ok {
		t.Fatal("block-form systems must be rejected")
	}
}

// TestListScopes_MissingDirIsEmpty: missing staxDir → empty slice, no
// error. The CLI check (requireProject) catches genuine missing-project
// states, so the inner helper just needs graceful no-data behavior.
func TestListScopes_MissingDirIsEmpty(t *testing.T) {
	var warn bytes.Buffer
	rows, err := listScopes(filepath.Join(t.TempDir(), "absent"), 5, &warn)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected empty, got %v", rows)
	}
}

// TestListScopes_EmptyDir: dir exists, no scopes yet — must return
// empty + nil error rather than treating "0 scopes" as a failure.
func TestListScopes_EmptyDir(t *testing.T) {
	var warn bytes.Buffer
	rows, err := listScopes(t.TempDir(), 5, &warn)
	if err != nil || len(rows) != 0 {
		t.Fatalf("err=%v rows=%v", err, rows)
	}
}

// TestListScopes_SortsByPrefix is the output-ordering contract: rows
// must come back in zero-padded prefix order (which equals numerical
// order). Seeded out-of-order on purpose to catch a regression where
// readdir order leaked through.
func TestListScopes_SortsByPrefix(t *testing.T) {
	dir := t.TempDir()
	writeScopeFile(t, dir, "00003-charlie.md", "status: valid\nsystems: [C]", "")
	writeScopeFile(t, dir, "00001-alpha.md", "status: valid\nsystems: [A]", "")
	writeScopeFile(t, dir, "00002-bravo.md", "status: deprecated\nsystems: [B]", "")
	var warn bytes.Buffer
	rows, err := listScopes(dir, 5, &warn)
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

// TestListScopes_IgnoresNonMatchingNames: filename-pattern filter
// silently drops stray files (README, short prefix, no .md extension,
// dir-named-like-file). No warning, because these aren't user-visible
// "broken scopes" — they're just noise that happens to share the dir.
func TestListScopes_IgnoresNonMatchingNames(t *testing.T) {
	dir := t.TempDir()
	writeScopeFile(t, dir, "00001-real.md", "status: valid\nsystems: [A]", "")
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
	rows, err := listScopes(dir, 5, &warn)
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

func TestListScopes_WarnsOnMatchingButMalformedFile(t *testing.T) {
	dir := t.TempDir()
	// Filename matches the pattern, content does not have frontmatter →
	// warn + skip, but do not abort sibling parsing.
	if err := os.WriteFile(filepath.Join(dir, "00001-broken.md"),
		[]byte("nope\n"), 0o600); err != nil {
		t.Fatalf("seed broken: %v", err)
	}
	writeScopeFile(t, dir, "00002-ok.md", "status: valid\nsystems: [A]", "")
	var warn bytes.Buffer
	rows, err := listScopes(dir, 5, &warn)
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

func TestListScopes_RespectsCustomWidth(t *testing.T) {
	dir := t.TempDir()
	writeScopeFile(t, dir, "0000042-foo.md", "status: valid\nsystems: [A]", "")
	// 5-digit file must be ignored when width=7.
	writeScopeFile(t, dir, "00001-bar.md", "status: valid\nsystems: [B]", "")
	var warn bytes.Buffer
	rows, err := listScopes(dir, 7, &warn)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(rows) != 1 || rows[0].slug != "0000042-foo" {
		t.Fatalf("rows = %v", rows)
	}
}

// ---------- scope list (--order + --overflow-keywords) ----------

func TestParseOrder(t *testing.T) {
	cases := []struct {
		in      string
		want    scopesListOrder
		wantErr bool
	}{
		{"asc", orderAsc, false},
		{"desc", orderDesc, false},
		{"", 0, true},
		{"ASC", 0, true},    // case-sensitive
		{"oldest", 0, true}, // no aliases
		{"garbage", 0, true},
	}
	for _, c := range cases {
		got, err := parseOrder(c.in)
		if c.wantErr {
			if err == nil {
				t.Fatalf("parseOrder(%q) = (%v, nil), want error", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Fatalf("parseOrder(%q) err = %v", c.in, err)
		}
		if got != c.want {
			t.Fatalf("parseOrder(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestSortScopeRows(t *testing.T) {
	rows := func() []scopeRow {
		return []scopeRow{
			{slug: "00002-bravo"},
			{slug: "00001-alpha"},
			{slug: "00003-charlie"},
		}
	}
	desc := rows()
	sortScopeRows(desc, orderDesc)
	if desc[0].slug != "00003-charlie" || desc[2].slug != "00001-alpha" {
		t.Fatalf("desc sort wrong: %v", desc)
	}
	asc := rows()
	sortScopeRows(asc, orderAsc)
	if asc[0].slug != "00001-alpha" || asc[2].slug != "00003-charlie" {
		t.Fatalf("asc sort wrong: %v", asc)
	}
	// Empty and single-element inputs must not panic.
	sortScopeRows(nil, orderDesc)
	sortScopeRows([]scopeRow{{slug: "00001-alone"}}, orderAsc)
}

func TestNormalizeKeywords(t *testing.T) {
	if got := normalizeKeywords(nil); got != nil {
		t.Fatalf("nil input: got %v, want nil", got)
	}
	if got := normalizeKeywords([]string{}); got != nil {
		t.Fatalf("empty input: got %v, want nil", got)
	}
	got := normalizeKeywords([]string{"Payment", "RETRY", ""})
	want := []string{"payment", "retry"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// seedBody is a test helper that writes a scope-format file whose body
// contains text. Returns the slug (filename minus extension).
func seedBody(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	content := "---\nstatus: valid\nsystems: [A]\n---\n" + body
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("seed %s: %v", name, err)
	}
	return strings.TrimSuffix(name, scopeFileExt)
}

func TestApplyOverflowNarrow_BelowThresholdNoChange(t *testing.T) {
	dir := t.TempDir()
	rows := []scopeRow{
		{slug: seedBody(t, dir, "00001-alpha.md", "anything")},
		{slug: seedBody(t, dir, "00002-bravo.md", "anything")},
	}
	got := applyOverflowNarrow(rows, []string{"nope"}, dir, 5)
	if len(got) != 2 {
		t.Fatalf("expected passthrough (≤threshold), got %v", got)
	}
}

func TestApplyOverflowNarrow_AtThresholdExactlyNoChange(t *testing.T) {
	// `>` semantics: a row count exactly equal to threshold must NOT
	// engage the narrow.
	dir := t.TempDir()
	threshold := 3
	rows := []scopeRow{
		{slug: seedBody(t, dir, "00001-alpha.md", "")},
		{slug: seedBody(t, dir, "00002-bravo.md", "")},
		{slug: seedBody(t, dir, "00003-charlie.md", "")},
	}
	got := applyOverflowNarrow(rows, []string{"anything"}, dir, threshold)
	if len(got) != threshold {
		t.Fatalf("at-threshold must passthrough, got %v", got)
	}
}

func TestApplyOverflowNarrow_OverflowNoKeywordsNoChange(t *testing.T) {
	// Caller declined to narrow → rows return unchanged even past
	// threshold; we never silently truncate without explicit keywords.
	dir := t.TempDir()
	threshold := 2
	rows := []scopeRow{
		{slug: seedBody(t, dir, "00001-alpha.md", "")},
		{slug: seedBody(t, dir, "00002-bravo.md", "")},
		{slug: seedBody(t, dir, "00003-charlie.md", "")},
	}
	got := applyOverflowNarrow(rows, nil, dir, threshold)
	if len(got) != 3 {
		t.Fatalf("no-keywords overflow must passthrough, got %v", got)
	}
}

func TestApplyOverflowNarrow_KeywordMatch(t *testing.T) {
	dir := t.TempDir()
	threshold := 2
	rows := []scopeRow{
		{slug: seedBody(t, dir, "00001-alpha.md", "no relevant text here")},
		{slug: seedBody(t, dir, "00002-bravo.md", "discusses Payment Service")},
		{slug: seedBody(t, dir, "00003-charlie.md", "discusses PAYMENT pipelines")},
	}
	got := applyOverflowNarrow(rows, []string{"payment"}, dir, threshold)
	if len(got) != 2 {
		t.Fatalf("expected 2 matches (case-insensitive), got %v", got)
	}
	if got[0].slug != "00002-bravo" || got[1].slug != "00003-charlie" {
		t.Fatalf("expected matches in input order: %v", got)
	}
}

func TestApplyOverflowNarrow_NoMatchFallsBackToTopN(t *testing.T) {
	// Threshold = 2, 3 rows pre-narrow, no keyword match → return
	// rows[:2] (the first two in the caller's sort order).
	dir := t.TempDir()
	threshold := 2
	rows := []scopeRow{
		{slug: seedBody(t, dir, "00001-alpha.md", "alpha body")},
		{slug: seedBody(t, dir, "00002-bravo.md", "bravo body")},
		{slug: seedBody(t, dir, "00003-charlie.md", "charlie body")},
	}
	got := applyOverflowNarrow(rows, []string{"zzzz-no-match"}, dir, threshold)
	if len(got) != threshold {
		t.Fatalf("expected top-N fallback (%d), got %v", threshold, got)
	}
	if got[0].slug != "00001-alpha" || got[1].slug != "00002-bravo" {
		t.Fatalf("fallback must preserve input order: %v", got)
	}
}

func TestApplyOverflowNarrow_BodyOnlyNotFrontmatter(t *testing.T) {
	// "Auth Service" appears in frontmatter `systems:` but NOT in the
	// body. The keyword search reads body only, so the row must NOT match.
	dir := t.TempDir()
	threshold := 2
	path := filepath.Join(dir, "00001-alpha.md")
	content := "---\nstatus: valid\nsystems: [auth-service]\n---\nno mention here\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	rows := []scopeRow{
		{slug: "00001-alpha"},
		{slug: seedBody(t, dir, "00002-bravo.md", "")},
		{slug: seedBody(t, dir, "00003-charlie.md", "")},
	}
	got := applyOverflowNarrow(rows, []string{"Auth Service"}, dir, threshold)
	// No body matched → fallback to top-N. If body matching were broken
	// and frontmatter leaked in, alpha would match and the count would
	// differ.
	if len(got) != threshold {
		t.Fatalf("expected fallback top-N, got %v", got)
	}
}

func TestApplyOverflowNarrow_MissingFileSkipped(t *testing.T) {
	// applyOverflowNarrow tolerates a row whose file vanished after
	// listScopes walked the directory (race against an external editor).
	// It contributes no match and doesn't abort the call.
	dir := t.TempDir()
	threshold := 2
	rows := []scopeRow{
		{slug: "00099-vanished"}, // no file on disk
		{slug: seedBody(t, dir, "00002-bravo.md", "matches")},
		{slug: seedBody(t, dir, "00003-charlie.md", "matches")},
	}
	got := applyOverflowNarrow(rows, []string{"matches"}, dir, threshold)
	if len(got) != 2 {
		t.Fatalf("expected only on-disk matches, got %v", got)
	}
}

func TestReadScopeBody(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "00001-good.md")
	if err := os.WriteFile(good, []byte("---\nstatus: valid\nsystems: [A]\n---\nthe body\n"), 0o600); err != nil {
		t.Fatalf("seed good: %v", err)
	}
	if body, ok := readScopeBody(good); !ok || !strings.Contains(body, "the body") {
		t.Fatalf("readScopeBody good: ok=%v body=%q", ok, body)
	}
	// Missing file → false.
	if _, ok := readScopeBody(filepath.Join(dir, "absent.md")); ok {
		t.Fatalf("readScopeBody missing-file must return false")
	}
	// No frontmatter → false (treated as malformed).
	plain := filepath.Join(dir, "00002-plain.md")
	if err := os.WriteFile(plain, []byte("no fence here\n"), 0o600); err != nil {
		t.Fatalf("seed plain: %v", err)
	}
	if _, ok := readScopeBody(plain); ok {
		t.Fatalf("readScopeBody no-frontmatter must return false")
	}
}

// ---------- scope lint ----------

func TestLoadMaxScopeLines_MissingLockReturnsDefault(t *testing.T) {
	if got := loadMaxPlanLines(t.TempDir()); got != defaultMaxScopeLines {
		t.Fatalf("got %d, want %d", got, defaultMaxScopeLines)
	}
}

func TestLoadMaxScopeLines_ValidLock(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, staxLockFile),
		[]byte(`{"max_scope_lines":17}`), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if got := loadMaxPlanLines(dir); got != 17 {
		t.Fatalf("got %d, want 17", got)
	}
}

func TestLoadMaxScopeLines_NonPositiveReturnsDefault(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, staxLockFile),
		[]byte(`{"max_scope_lines":0}`), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if got := loadMaxPlanLines(dir); got != defaultMaxScopeLines {
		t.Fatalf("got %d, want %d", got, defaultMaxScopeLines)
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

// TestParseRegistry_MissingFileReturnsEmpty: an absent _data_systems.yaml
// is a legitimate pre-init / fresh-project state — the parser must return
// an empty (but non-nil) registry so callers don't need a special-case
// guard before indexing byID/byName.
func TestParseRegistry_MissingFileReturnsEmpty(t *testing.T) {
	reg := parseRegistry(filepath.Join(t.TempDir(), "absent"))
	if reg.byID == nil || reg.byName == nil {
		t.Fatalf("expected non-nil maps, got %+v", reg)
	}
	if len(reg.byID) != 0 || len(reg.byName) != 0 {
		t.Fatalf("expected empty maps, got %+v", reg)
	}
}

// TestParseRegistry_HappyPath covers the realistic _data_systems.yaml
// structure: each entry carries id + name + brief, the id is kebab-case, and
// entries living under sibling top-level keys (`other:` below) are
// ignored. Both lookup directions are populated symmetrically.
func TestParseRegistry_HappyPath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, staxSystemsFile)
	body := `# top comment
systems:
  - id: auth-service
    name: Auth Service
    brief: handles auth
  - id: billing-service
    name: "Billing Service"
    brief: handles billing

other:
  - id: not-in-systems
    name: NotInSystems
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	reg := parseRegistry(path)
	if reg.byID["auth-service"] != "Auth Service" || reg.byID["billing-service"] != "Billing Service" {
		t.Fatalf("byID missing entries: %v", reg.byID)
	}
	if reg.byName["Auth Service"] != "auth-service" || reg.byName["Billing Service"] != "billing-service" {
		t.Fatalf("byName missing entries: %v", reg.byName)
	}
	if _, has := reg.byID["not-in-systems"]; has {
		t.Fatalf("entries outside the systems block must be ignored: %v", reg.byID)
	}
}

// TestParseRegistry_SkipsPartialEntries: an entry with only `id:` or only
// `name:` is dropped silently — lint surfaces the gap when a scope
// references the partially defined slug, so the parser doesn't need to fail
// here. Whole entries on either side of the bad one must still land.
func TestParseRegistry_SkipsPartialEntries(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, staxSystemsFile)
	body := `systems:
  - id: complete-one
    name: Complete One
  - id: id-only
  - name: Name Only
  - id: complete-two
    name: Complete Two
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	reg := parseRegistry(path)
	if reg.byID["complete-one"] != "Complete One" {
		t.Fatalf("complete-one missing: %v", reg.byID)
	}
	if reg.byID["complete-two"] != "Complete Two" {
		t.Fatalf("complete-two missing: %v", reg.byID)
	}
	if _, has := reg.byID["id-only"]; has {
		t.Fatalf("id-only entry should be dropped (no name): %v", reg.byID)
	}
	if _, has := reg.byName["Name Only"]; has {
		t.Fatalf("Name Only entry should be dropped (no id): %v", reg.byName)
	}
}

// TestParseRegistry_MultilineEntries pins that an item's `id:` and
// `name:` can live on the same line as `- ` or on indented continuation
// lines — both forms appear in the wild because the documented example
// (now in scope/SKILL.md Appendix C) shows the continuation form, but
// a hand-edit may collapse onto one line.
func TestParseRegistry_MultilineEntries(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, staxSystemsFile)
	body := `systems:
  - id: same-line
    name: Same Line
  - name: Name First
    id: name-first
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	reg := parseRegistry(path)
	if reg.byID["same-line"] != "Same Line" {
		t.Fatalf("same-line missing: %v", reg.byID)
	}
	if reg.byID["name-first"] != "Name First" {
		t.Fatalf("name-first missing: %v", reg.byID)
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

// validScopeFM is the standard passing frontmatter+body used by lint tests.
// Defined once so per-failure cases can override one field at a time. The
// title must slugify to "foo" so the filename "00001-foo.md" matches.
const (
	validScopeFM   = "title: Foo\nstatus: valid\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z"
	validScopeBody = "## Goal\nDo a thing.\n\n## Approach\n- A\n\n## Tasks\n- [ ] The Auth Service shall do a thing.\n"
)

// fixtureScopeName is the standard scope filename used by every lint test
// case. Single source of truth so the extension (scopeFileExt) doesn't get
// duplicated as `fixtureScopeName` across call sites — AGENTS.md hard rule.
var fixtureScopeName = "00001-foo" + scopeFileExt

// fixtureRegistryPath is the .stax/_data_systems.yaml path passed to
// lintScopeFile as its `registryPath` arg. Composed from the constants so
// a rename of staxDir or staxSystemsFile lands in exactly one place.
var fixtureRegistryPath = filepath.Join(staxDir, staxSystemsFile)

// newRegistry builds a `registry` value from alternating id, name args:
// `newRegistry("auth-service", "Auth Service", "billing-service",
// "Billing Service")`. Panics on an odd-length call so a typo'd fixture
// fails loudly inside the test rather than via a confusing downstream
// mismatch. The two maps end up inverses of each other.
func newRegistry(pairs ...string) registry {
	if len(pairs)%2 != 0 {
		panic("newRegistry: pairs must be even (alternating id, name)")
	}
	byID := make(map[string]string, len(pairs)/2)
	byName := make(map[string]string, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		id, name := pairs[i], pairs[i+1]
		byID[id] = name
		byName[name] = id
	}
	return registry{byID: byID, byName: byName}
}

func TestLintScopeFile_HappyPath(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName, validScopeFM, validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if len(findings) != 0 {
		t.Fatalf("expected no findings, got %v", findings)
	}
}

func TestLintScopeFile_BadFilename(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, "BAD-foo.md", validScopeFM, validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "filename") {
		t.Fatalf("expected filename finding, got %v", findings)
	}
}

func TestLintScopeFile_TooLong(t *testing.T) {
	dir := t.TempDir()
	bigBody := validScopeBody + strings.Repeat("x\n", 100)
	path := writeScopeFile(t, dir, fixtureScopeName, validScopeFM, bigBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "max is 30") {
		t.Fatalf("expected line-cap finding, got %v", findings)
	}
}

func TestLintScopeFile_NoFrontmatter(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, fixtureScopeName)
	if err := os.WriteFile(path, []byte("just body\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	findings := lintScopeFile(path, 5, 30, newRegistry(),
		map[string]bool{}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "missing YAML frontmatter") {
		t.Fatalf("expected frontmatter finding, got %v", findings)
	}
}

func TestLintScopeFile_BadStatus(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: bogus\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z", validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `status "bogus" is not one of`) {
		t.Fatalf("expected status finding, got %v", findings)
	}
}

func TestLintScopeFile_SystemNotInRegistry(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [Ghost]\ncreated: 2026-05-23T14:30:00Z",
		"## Goal\n## Approach\n## Tasks\n- [ ] The Ghost shall haunt.\n")
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `declared system "Ghost" is not in`) {
		t.Fatalf("expected registry finding, got %v", findings)
	}
}

func TestLintScopeFile_SupersedesMissingSibling(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nsupersedes: [00099-nope]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `supersedes "00099-nope"`) {
		t.Fatalf("expected supersedes finding, got %v", findings)
	}
}

func TestLintScopeFile_EARSSubjectMismatch(t *testing.T) {
	dir := t.TempDir()
	// systems declares Auth, task body names Billing — both violations should fire.
	body := "## Goal\n## Approach\n## Tasks\n- [ ] The Billing Service shall send invoices.\n"
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z", body)
	findings := lintScopeFile(path, 5, 30,
		newRegistry("auth-service", "Auth Service", "billing-service", "Billing Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "EARS tasks name systems not in `systems:`") {
		t.Fatalf("expected EARS-in-tasks finding, got %v", findings)
	}
	if !containsSubstr(findings, "`systems:` declares systems not used in any EARS task") {
		t.Fatalf("expected EARS-in-systems finding, got %v", findings)
	}
}

// TestLintScopeFile_FrontmatterIDNotInRegistry covers the id-membership
// part of the new id-based contract: an inline `systems:` entry that
// isn't a key in the registry's id index must surface a finding even
// though the EARS body might still resolve cleanly through a different
// registered name.
func TestLintScopeFile_FrontmatterIDNotInRegistry(t *testing.T) {
	dir := t.TempDir()
	// Frontmatter declares an unknown id; EARS body references the only
	// registered system. Both findings should fire (id-not-in-registry +
	// the declared/subject id-set divergence).
	body := "## Goal\n## Approach\n## Tasks\n- [ ] The Auth Service shall do.\n"
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [ghost-service]\ncreated: 2026-05-23T14:30:00Z", body)
	findings := lintScopeFile(path, 5, 30,
		newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `declared system "ghost-service" is not in`) {
		t.Fatalf("expected id-not-in-registry finding, got %v", findings)
	}
}

// TestLintScopeFile_EARSSubjectUnknownName: an EARS subject (display name
// in the body text) that has no registry entry surfaces the new
// "EARS subject is not in <registry>" finding. The subject-name → id
// resolution is the critical part of the new id-aware lint.
func TestLintScopeFile_EARSSubjectUnknownName(t *testing.T) {
	dir := t.TempDir()
	body := "## Goal\n## Approach\n## Tasks\n- [ ] The Phantom Service shall haunt.\n"
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z", body)
	findings := lintScopeFile(path, 5, 30,
		newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `EARS subject "Phantom Service" is not in`) {
		t.Fatalf("expected unknown-subject finding, got %v", findings)
	}
}

// TestLintScopeFile_EARSNameResolvesToDeclaredID is the happy path of the
// name↔id translation: the body uses the display name, the frontmatter
// uses the kebab id, and the registry resolves one to the other. No
// findings should fire.
func TestLintScopeFile_EARSNameResolvesToDeclaredID(t *testing.T) {
	dir := t.TempDir()
	body := "## Goal\nDo a thing.\n\n## Approach\n- A\n\n## Tasks\n- [ ] The Auth Service shall act.\n"
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z", body)
	findings := lintScopeFile(path, 5, 30,
		newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if len(findings) != 0 {
		t.Fatalf("expected zero findings on resolved name/id pair, got %v", findings)
	}
}

// TestLintScopeFile_MultipleEARSSubjectsResolvedConsistently: a scope with
// two distinct subjects in the body, both registered and both declared
// in `systems:` by their ids, lints cleanly. Guards against the
// id-set comparison silently collapsing duplicates when it shouldn't.
func TestLintScopeFile_MultipleEARSSubjectsResolvedConsistently(t *testing.T) {
	dir := t.TempDir()
	body := "## Goal\nx\n\n## Approach\n- A\n\n## Tasks\n" +
		"- [ ] The Auth Service shall authenticate.\n" +
		"- [ ] The Billing Service shall invoice.\n"
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service, billing-service]\ncreated: 2026-05-23T14:30:00Z",
		body)
	findings := lintScopeFile(path, 5, 30,
		newRegistry("auth-service", "Auth Service", "billing-service", "Billing Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if len(findings) != 0 {
		t.Fatalf("expected zero findings on two cleanly-resolved subjects, got %v", findings)
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

// ---------- scope slugify ----------

// TestSlugify covers the kebab-case transformation used by `stax scopes
// slugify` and by lintFilenameMatchesTitle. Both surfaces share the same
// function, so any future change to the algorithm is caught here once.
func TestSlugify(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"Hello World", "hello-world"},
		{"Foo bar", "foo-bar"},
		{"Joe's scope", "joe-s-scope"},
		{"Foo // Bar", "foo-bar"},
		{"  Leading & trailing  ", "leading-trailing"},
		{"ALL CAPS", "all-caps"},
		{"already-kebab-case", "already-kebab-case"},
		{"café", "caf"},
		{"", ""},
		{"   ", ""},
		{"---", ""},
		{"v1.2.3 release", "v1-2-3-release"},
		// Trailing punctuation is trimmed by the surrounding `-` collapse.
		{"Foo!", "foo"},
		{"!!!Foo!!!", "foo"},
		// Dots between word fragments collapse to a single `-`.
		{"foo.bar.baz", "foo-bar-baz"},
		// Whitespace classes other than space (tab, newline) are treated
		// the same as space — anything outside [a-z0-9] is a separator.
		{"Foo\tBar", "foo-bar"},
		{"Foo\nBar", "foo-bar"},
		// Runs of any combination of separators collapse to a single `-`.
		{"Foo   Bar", "foo-bar"},
		{"Foo - Bar", "foo-bar"},
		// Pure numerics survive (filename regex allows leading digit too).
		{"123", "123"},
		// Wholly non-ASCII collapses to empty (every char is a separator,
		// trim drops the dashes) — the caller treats empty as an error.
		{"プラン", ""},
		// Mixed ASCII + non-ASCII keeps the ASCII portion.
		{"Scope プラン", "scope"},
		// Embedded quotes are stripped by the non-alnum class.
		{`Joe's "Cool" Scope`, "joe-s-cool-scope"},
		// Leading-dash titles slugify correctly when fed in. runScopesSlugify
		// deliberately skips flag.Parse for this reason, so titles like
		// "---draft note" reach this function unmangled from the CLI.
		{"-foo bar", "foo-bar"},
		{"---foo---", "foo"},
		{"--draft note", "draft-note"},
		// Slash-separated paths flatten to a single slug.
		{"lib/foo/bar", "lib-foo-bar"},
		// Underscores are non-alnum → become separators (so kebab is the
		// only on-disk format, even if the title uses snake_case).
		{"foo_bar_baz", "foo-bar-baz"},
	}
	for _, c := range cases {
		if got := slugify(c.in); got != c.want {
			t.Fatalf("slugify(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// ---------- new lint checks (title / created / order / filename↔title) ----------

func TestLintScopeFile_MissingTitle(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"status: valid\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z", validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "missing required `title:`") {
		t.Fatalf("expected title finding, got %v", findings)
	}
}

func TestLintScopeFile_EmptyTitle(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: \"\"\nstatus: valid\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z", validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "`title:` value is empty") {
		t.Fatalf("expected empty-title finding, got %v", findings)
	}
}

func TestLintScopeFile_MissingCreated(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]", validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "missing required `created:`") {
		t.Fatalf("expected created finding, got %v", findings)
	}
}

func TestLintScopeFile_MalformedCreated(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\ncreated: yesterday", validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `"yesterday" is not an ISO 8601 UTC timestamp`) {
		t.Fatalf("expected malformed-created finding, got %v", findings)
	}
}

// TestLintScopeFile_DateOnlyCreated pins that the historical date-only
// form (`YYYY-MM-DD`) is no longer accepted — `created:` must now carry a
// full UTC timestamp so scopes authored on the same day still have a
// total order.
func TestLintScopeFile_DateOnlyCreated(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\ncreated: 2026-05-23", validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `"2026-05-23" is not an ISO 8601 UTC timestamp`) {
		t.Fatalf("expected date-only-rejection finding, got %v", findings)
	}
}

func TestLintScopeFile_TitleNotFirst(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"status: valid\ntitle: Foo\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z", validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "must be the first frontmatter field") {
		t.Fatalf("expected order finding, got %v", findings)
	}
}

func TestLintScopeFile_CreatedNotLast(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\ncreated: 2026-05-23T14:30:00Z\nstatus: valid\nsystems: [auth-service]", validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "must be the last frontmatter field") {
		t.Fatalf("expected order finding, got %v", findings)
	}
}

func TestLintScopeFile_FilenameDoesNotMatchTitle(t *testing.T) {
	dir := t.TempDir()
	// Title slugifies to "totally-different" but filename slug is "foo".
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Totally Different\nstatus: valid\nsystems: [auth-service]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "does not match slugify(title)") {
		t.Fatalf("expected filename↔title finding, got %v", findings)
	}
}

// ---------- extends / extended_by lint ----------

// TestLintScopeFile_DanglingExtends: a slug in `extends:` that doesn't
// resolve to a sibling scope must be reported. Mirrors the supersedes
// finding format so the user message is consistent across all three
// cross-scope reference fields.
func TestLintScopeFile_DanglingExtends(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nextends: [00099-nope]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `extends "00099-nope"`) {
		t.Fatalf("expected dangling-extends finding, got %v", findings)
	}
}

// TestLintScopeFile_DanglingExtendedBy: the back-pointer field has the
// same dangling-slug rule as its forward twin.
func TestLintScopeFile_DanglingExtendedBy(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nextended_by: [00099-nope]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `extended_by "00099-nope"`) {
		t.Fatalf("expected dangling-extended_by finding, got %v", findings)
	}
}

// TestLintScopeFile_SelfExtendsRejected: a scope cannot extend itself —
// the relationship has no semantic meaning and would always pass the
// dangling-slug check (the slug obviously exists). Catch it explicitly.
func TestLintScopeFile_SelfExtendsRejected(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nextends: [00001-foo]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "extends cannot reference the scope itself") {
		t.Fatalf("expected self-extends finding, got %v", findings)
	}
}

// TestLintScopeFile_ExtendsBidirectionalMissingBacklink: scope claims to
// extend a predecessor, but the predecessor's extended_by: doesn't list
// this scope. Bidirectional invariant must fire.
func TestLintScopeFile_ExtendsBidirectionalMissingBacklink(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nextends: [00002-bar]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	relations := scopesRelations{
		extends: map[string]map[string]bool{
			"00001-foo": {"00002-bar": true},
		},
		// 00002-bar exists in knownSlugs but its extended_by set is empty.
		extendedBy: map[string]map[string]bool{},
	}
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true, "00002-bar": true},
		relations, fixtureRegistryPath)
	if !containsSubstr(findings, "does not list this scope in its `extended_by:` array") {
		t.Fatalf("expected bidirectional finding, got %v", findings)
	}
}

// TestLintScopeFile_ExtendedByBidirectionalMissingForwardLink: same as
// above in the opposite direction — predecessor says it's extended by
// scope X, but X's extends: doesn't include the predecessor.
func TestLintScopeFile_ExtendedByBidirectionalMissingForwardLink(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nextended_by: [00002-bar]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	relations := scopesRelations{
		extendedBy: map[string]map[string]bool{
			"00001-foo": {"00002-bar": true},
		},
		extends: map[string]map[string]bool{},
	}
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true, "00002-bar": true},
		relations, fixtureRegistryPath)
	if !containsSubstr(findings, "does not list this scope in its `extends:` array") {
		t.Fatalf("expected bidirectional finding, got %v", findings)
	}
}

// TestLintScopeFile_ExtendsBidirectionalHappy: both sides of the link
// agree → no finding.
func TestLintScopeFile_ExtendsBidirectionalHappy(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nextends: [00002-bar]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	relations := scopesRelations{
		extends: map[string]map[string]bool{
			"00001-foo": {"00002-bar": true},
		},
		extendedBy: map[string]map[string]bool{
			"00002-bar": {"00001-foo": true},
		},
	}
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true, "00002-bar": true},
		relations, fixtureRegistryPath)
	for _, f := range findings {
		if strings.Contains(f, "does not list this scope") {
			t.Fatalf("unexpected bidirectional finding on symmetric link: %v", findings)
		}
	}
}

// TestScanScopeRelations pins the cross-scope map builder: returns the
// inline-array contents per slug for every forward/back field, skipping
// files that can't be parsed.
func TestScanScopeRelations(t *testing.T) {
	dir := t.TempDir()
	writeScopeFile(t, dir, "00001-foo.md",
		"title: Foo\nstatus: valid\nsystems: [A]\nextends: [00002-bar]\ncreated: 2026-05-23T14:30:00Z", "")
	writeScopeFile(t, dir, "00002-bar.md",
		"title: Bar\nstatus: valid\nsystems: [A]\nextended_by: [00001-foo]\nsupersedes: [00003-old]\ncreated: 2026-05-23T14:30:00Z", "")
	writeScopeFile(t, dir, "00003-old.md",
		"title: Old\nstatus: superseded\nsystems: [A]\nsuperseded_by: [00002-bar]\ncreated: 2026-05-23T14:30:00Z", "")
	// File with no frontmatter is silently skipped.
	if err := os.WriteFile(filepath.Join(dir, "00004-noop.md"), []byte("body only\n"), 0o600); err != nil {
		t.Fatalf("seed noop: %v", err)
	}

	files := []string{
		filepath.Join(dir, "00001-foo.md"),
		filepath.Join(dir, "00002-bar.md"),
		filepath.Join(dir, "00003-old.md"),
		filepath.Join(dir, "00004-noop.md"),
	}
	r := scanPlansRelations(files)
	if !r.extends["00001-foo"]["00002-bar"] {
		t.Fatalf("extends missing 00001-foo → 00002-bar: %v", r.extends)
	}
	if !r.extendedBy["00002-bar"]["00001-foo"] {
		t.Fatalf("extendedBy missing 00002-bar → 00001-foo: %v", r.extendedBy)
	}
	if !r.supersedes["00002-bar"]["00003-old"] {
		t.Fatalf("supersedes missing 00002-bar → 00003-old: %v", r.supersedes)
	}
	if !r.supersededBy["00003-old"]["00002-bar"] {
		t.Fatalf("supersededBy missing 00003-old → 00002-bar: %v", r.supersededBy)
	}
	if _, has := r.extends["00004-noop"]; has {
		t.Fatalf("malformed file should not appear in extends: %v", r.extends)
	}
}

// TestLintScopeFile_DanglingSupersededBy: a dangling slug in
// `superseded_by:` (back link on the predecessor) must be reported.
func TestLintScopeFile_DanglingSupersededBy(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: superseded\nsystems: [auth-service]\nsuperseded_by: [00099-nope]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, `superseded_by "00099-nope"`) {
		t.Fatalf("expected dangling-superseded_by finding, got %v", findings)
	}
}

// TestLintScopeFile_SelfSupersedesRejected: a scope can't supersede itself.
func TestLintScopeFile_SelfSupersedesRejected(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nsupersedes: [00001-foo]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true}, scopesRelations{}, fixtureRegistryPath)
	if !containsSubstr(findings, "supersedes cannot reference the scope itself") {
		t.Fatalf("expected self-supersedes finding, got %v", findings)
	}
}

// TestLintScopeFile_SupersedesBidirectionalMissingBacklink: B claims to
// supersede A, A's superseded_by: doesn't list B.
func TestLintScopeFile_SupersedesBidirectionalMissingBacklink(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nsupersedes: [00002-bar]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	relations := scopesRelations{
		supersedes: map[string]map[string]bool{
			"00001-foo": {"00002-bar": true},
		},
		supersededBy: map[string]map[string]bool{},
	}
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true, "00002-bar": true},
		relations, fixtureRegistryPath)
	if !containsSubstr(findings, "does not list this scope in its `superseded_by:` array") {
		t.Fatalf("expected supersedes-bidirectional finding, got %v", findings)
	}
}

// TestLintScopeFile_SupersededByBidirectionalMissingForwardLink: A says
// it's superseded by B, B's supersedes: doesn't list A.
func TestLintScopeFile_SupersededByBidirectionalMissingForwardLink(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: superseded\nsystems: [auth-service]\nsuperseded_by: [00002-bar]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	relations := scopesRelations{
		supersededBy: map[string]map[string]bool{
			"00001-foo": {"00002-bar": true},
		},
		supersedes: map[string]map[string]bool{},
	}
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true, "00002-bar": true},
		relations, fixtureRegistryPath)
	if !containsSubstr(findings, "does not list this scope in its `supersedes:` array") {
		t.Fatalf("expected superseded_by-bidirectional finding, got %v", findings)
	}
}

// TestLintScopeFile_SupersedesBidirectionalHappy: both sides agree → no
// bidirectional finding.
func TestLintScopeFile_SupersedesBidirectionalHappy(t *testing.T) {
	dir := t.TempDir()
	path := writeScopeFile(t, dir, fixtureScopeName,
		"title: Foo\nstatus: valid\nsystems: [auth-service]\nsupersedes: [00002-bar]\ncreated: 2026-05-23T14:30:00Z",
		validScopeBody)
	relations := scopesRelations{
		supersedes: map[string]map[string]bool{
			"00001-foo": {"00002-bar": true},
		},
		supersededBy: map[string]map[string]bool{
			"00002-bar": {"00001-foo": true},
		},
	}
	findings := lintScopeFile(path, 5, 30, newRegistry("auth-service", "Auth Service"),
		map[string]bool{"00001-foo": true, "00002-bar": true},
		relations, fixtureRegistryPath)
	for _, f := range findings {
		if strings.Contains(f, "does not list this scope") {
			t.Fatalf("unexpected bidirectional finding on symmetric supersedes link: %v", findings)
		}
	}
}

// ---------- filterPlanRows (status + system filters extracted from runScopesList) ----------

// TestFilterScopeRows_NoFilters pins the "empty set means pass-through"
// shorthand: an unset --status / --system flag must not silently drop
// any row. Both nil and len==0 sets count as "no filter".
func TestFilterScopeRows_NoFilters(t *testing.T) {
	rows := []scopeRow{
		{slug: "00001-a", status: "valid", systems: []string{"x"}},
		{slug: "00002-b", status: "deprecated", systems: []string{"y"}},
	}
	if got := filterPlanRows(rows, nil, nil); len(got) != 2 {
		t.Fatalf("nil sets: expected 2 rows, got %v", got)
	}
	if got := filterPlanRows(rows, map[string]bool{}, map[string]bool{}); len(got) != 2 {
		t.Fatalf("empty sets: expected 2 rows, got %v", got)
	}
}

// TestFilterScopeRows_StatusOnly verifies the --status path in isolation:
// only rows whose status is in the set survive; systems are ignored
// when systemSet is empty.
func TestFilterScopeRows_StatusOnly(t *testing.T) {
	rows := []scopeRow{
		{slug: "00001-a", status: "valid", systems: []string{"x"}},
		{slug: "00002-b", status: "deprecated", systems: []string{"y"}},
		{slug: "00003-c", status: "valid", systems: []string{"z"}},
	}
	got := filterPlanRows(rows, map[string]bool{"valid": true}, nil)
	if len(got) != 2 || got[0].slug != "00001-a" || got[1].slug != "00003-c" {
		t.Fatalf("status-only filter wrong: %v", got)
	}
}

// TestFilterScopeRows_SystemOnly mirrors the status-only case for --system:
// OR semantics across the systems slice (any element in the set keeps
// the row), status is ignored when statusSet is empty.
func TestFilterScopeRows_SystemOnly(t *testing.T) {
	rows := []scopeRow{
		{slug: "00001-a", status: "valid", systems: []string{"x", "auth"}},
		{slug: "00002-b", status: "deprecated", systems: []string{"y"}},
		{slug: "00003-c", status: "valid", systems: []string{"auth"}},
	}
	got := filterPlanRows(rows, nil, map[string]bool{"auth": true})
	if len(got) != 2 || got[0].slug != "00001-a" || got[1].slug != "00003-c" {
		t.Fatalf("system-only filter wrong: %v", got)
	}
}

// TestFilterScopeRows_StatusAndSystem pins the intersection: a row must
// pass BOTH filters when both are set. Catches a regression where the
// inline loop accidentally turned the AND into an OR.
func TestFilterScopeRows_StatusAndSystem(t *testing.T) {
	rows := []scopeRow{
		{slug: "00001-a", status: "valid", systems: []string{"auth"}},      // pass
		{slug: "00002-b", status: "valid", systems: []string{"billing"}},   // fail system
		{slug: "00003-c", status: "deprecated", systems: []string{"auth"}}, // fail status
		{slug: "00004-d", status: "valid", systems: []string{"auth"}},      // pass
	}
	got := filterPlanRows(rows,
		map[string]bool{"valid": true},
		map[string]bool{"auth": true})
	if len(got) != 2 || got[0].slug != "00001-a" || got[1].slug != "00004-d" {
		t.Fatalf("intersection filter wrong: %v", got)
	}
}

// TestApplyOverflowNarrow_PostStatusSystemKeywordChain is the unit-level
// analogue of the bash / PS1 e2e case that exercises
// status+system+overflow-keywords on a status∩system count above the
// threshold. The status+system filter is applied via filterPlanRows
// FIRST, so all distractors that share status AND system but lack the
// body keyword can be eliminated ONLY by the overflow narrow. Cross-
// filter distractors (different status or different system, but body
// contains the keyword) are dropped by filterPlanRows before overflow
// ever sees them.
func TestApplyOverflowNarrow_PostStatusSystemKeywordChain(t *testing.T) {
	dir := t.TempDir()
	threshold := 20
	// Threshold+2 same-status+same-system rows, body without the keyword.
	rows := make([]scopeRow, 0, threshold+4)
	for i := 1; i <= threshold+2; i++ {
		name := filenameForPrefix(i, "scope")
		body := strings.Repeat(" ", 0) + "generic body content " + name
		rows = append(rows, scopeRow{
			slug:    seedBody(t, dir, name, body),
			status:  "valid",
			systems: []string{"payment-service"},
		})
	}
	// Overwrite two of them with bodies that DO contain the keyword.
	// The rows slice already references those slugs; rewriting the file
	// is enough.
	for _, n := range []int{5, 17} {
		name := filenameForPrefix(n, "scope")
		body := "scope covers exponential retry backoff"
		_ = seedBody(t, dir, name, body)
	}
	// Two cross-filter distractors with keyword in body. These would be
	// dropped by filterPlanRows BEFORE overflow runs; include them in
	// the pre-filter input so the test mirrors the runScopesList pipeline
	// order (filterPlanRows -> applyOverflowNarrow).
	rows = append(rows,
		scopeRow{
			slug:   seedBody(t, dir, "0098-wrong-status.md", "deprecated scope that mentions retry"),
			status: "deprecated", systems: []string{"payment-service"},
		},
		scopeRow{
			slug:   seedBody(t, dir, "0099-wrong-system.md", "other-service scope that mentions retry"),
			status: "valid", systems: []string{"other-service"},
		},
	)
	pre := filterPlanRows(rows,
		map[string]bool{"valid": true},
		map[string]bool{"payment-service": true})
	if len(pre) != threshold+2 {
		t.Fatalf("filterPlanRows must drop both cross-filter distractors; got %d rows, want %d", len(pre), threshold+2)
	}
	got := applyOverflowNarrow(pre, []string{"retry"}, dir, threshold)
	if len(got) != 2 {
		t.Fatalf("overflow narrow must keep exactly the two keyword matchers; got %d rows: %v", len(got), got)
	}
	wantSlugs := map[string]bool{
		filenameForPrefixStem(5, "scope"):  true,
		filenameForPrefixStem(17, "scope"): true,
	}
	for _, r := range got {
		if !wantSlugs[r.slug] {
			t.Fatalf("unexpected slug %q in overflow result; want only %v", r.slug, wantSlugs)
		}
	}
}

// filenameForPrefix builds a 4-wide-prefix filename like "0005-scope.md"
// used by the chain test to seed scope file with predictable slugs.
func filenameForPrefix(n int, stem string) string {
	return filenameForPrefixStem(n, stem) + scopeFileExt
}

func filenameForPrefixStem(n int, stem string) string {
	return fmt.Sprintf("%04d-%s", n, stem)
}

// ---------- direct helper tests (previously only transitively covered) ----------

// TestLintFilename pins the regex form independently of lintScopeFile,
// so a filename-only regression doesn't get masked by a co-occurring
// frontmatter finding in the same per-file invocation.
func TestLintFilename(t *testing.T) {
	cases := []struct {
		name     string
		width    int
		wantFind bool
	}{
		{"00001-foo.md", 5, false},
		{"00001-multi-word-slug.md", 5, false},
		{"0001-foo.md", 4, false},
		{"00001-foo.md", 4, true},       // prefix width mismatch
		{"00001-FOO.md", 5, true},       // uppercase slug
		{"00001foo.md", 5, true},        // missing dash
		{"00001-.md", 5, true},          // empty slug
		{"00001-foo", 5, true},          // missing .md
		{"00001-foo.markdown", 5, true}, // wrong extension
		{"00001-foo-.md", 5, false},     // trailing dash is allowed by [a-z0-9-]*
		{"abcde-foo.md", 5, true},       // non-numeric prefix
	}
	for _, c := range cases {
		got := lintFilename(c.name, c.width)
		if (len(got) > 0) != c.wantFind {
			t.Fatalf("lintFilename(%q, %d) findings=%v want findings=%v", c.name, c.width, got, c.wantFind)
		}
	}
}

// TestLintLineCount exercises the +1 adjustment for files without a
// trailing newline so two visually-identical files produce the same
// count. Also pins the cap boundary (exactly maxLines = no finding).
func TestLintLineCount(t *testing.T) {
	cases := []struct {
		text     string
		max      int
		wantFind bool
	}{
		{"a\nb\nc\n", 3, false},
		{"a\nb\nc", 3, false},     // missing trailing newline counts the same
		{"a\nb\nc\nd\n", 3, true}, // exceeds
		{"a\nb\nc\nd", 3, true},   // exceeds (no trailing newline)
		{"", 1, false},            // empty file ≤ cap
		{"only-one-line", 1, false},
	}
	for _, c := range cases {
		got := lintLineCount(c.text, c.max)
		if (len(got) > 0) != c.wantFind {
			t.Fatalf("lintLineCount(%q,%d) = %v; want findings=%v", c.text, c.max, got, c.wantFind)
		}
	}
}

// TestSplitFrontmatter pins the four observable forms of the YAML
// frontmatter fence: well-formed, missing, unterminated, and CRLF.
// CRLF tolerance matters because Windows-edited scope file routinely
// land with \r\n endings.
func TestSplitFrontmatter(t *testing.T) {
	// Well-formed: returns (fm, body, nil, false).
	fm, body, findings, stop := splitFrontmatter("---\ntitle: a\n---\nbody here\n")
	if stop || len(findings) > 0 {
		t.Fatalf("well-formed: stop=%v findings=%v", stop, findings)
	}
	if !strings.Contains(fm, "title: a") || !strings.Contains(body, "body here") {
		t.Fatalf("well-formed: fm=%q body=%q", fm, body)
	}
	// Missing leading fence → stop with one finding.
	_, _, findings, stop = splitFrontmatter("title: a\nbody here\n")
	if !stop || len(findings) != 1 {
		t.Fatalf("missing FM: stop=%v findings=%v", stop, findings)
	}
	// Unterminated FM → stop with one finding.
	_, _, findings, stop = splitFrontmatter("---\ntitle: a\nno close\n")
	if !stop || len(findings) != 1 {
		t.Fatalf("unterminated FM: stop=%v findings=%v", stop, findings)
	}
}

// TestLintStatus walks the four allowed-status outcomes (missing,
// disallowed, each allowed value) so a future allowlist edit can't
// silently broaden what `scopes lint` accepts.
func TestLintStatus(t *testing.T) {
	if got := lintStatus("title: x\n"); len(got) == 0 {
		t.Fatal("missing status: expected finding")
	}
	if got := lintStatus("status: wip\n"); len(got) == 0 {
		t.Fatal("disallowed status: expected finding")
	}
	for _, s := range []string{"valid", "superseded", "deprecated"} {
		if got := lintStatus("status: " + s + "\n"); len(got) > 0 {
			t.Fatalf("allowed status %q produced findings: %v", s, got)
		}
	}
}

// TestLintSystems covers the inline-array contract directly: missing,
// empty array, unknown ids, and the "block form is rejected" rule that
// keeps the regex tight.
func TestLintSystems(t *testing.T) {
	reg := newRegistry("auth", "Auth Service", "billing", "Billing Service")
	// Missing → one finding.
	declared, findings := lintSystems("title: x\n", reg, fixtureRegistryPath)
	if len(declared) != 0 || len(findings) != 1 {
		t.Fatalf("missing: declared=%v findings=%v", declared, findings)
	}
	// Empty array → declared empty + one finding about being empty.
	declared, findings = lintSystems("systems: []\n", reg, fixtureRegistryPath)
	if len(declared) != 0 || len(findings) != 1 {
		t.Fatalf("empty: declared=%v findings=%v", declared, findings)
	}
	// Unknown id → finding per unknown.
	_, findings = lintSystems("systems: [auth, nope, other]\n", reg, fixtureRegistryPath)
	if len(findings) != 2 {
		t.Fatalf("two unknowns: %v", findings)
	}
	// Block form rejected (regex doesn't match) — treated as missing.
	declared, findings = lintSystems("systems:\n  - auth\n  - billing\n", reg, fixtureRegistryPath)
	if len(declared) != 0 || len(findings) != 1 {
		t.Fatalf("block form: declared=%v findings=%v", declared, findings)
	}
}

// TestLintRelationArray covers the shared form for supersedes /
// extends / extended_by / superseded_by: self-reference and dangling
// slug references each produce one finding.
func TestLintRelationArray(t *testing.T) {
	known := map[string]bool{"00001-a": true, "00002-b": true}
	// Field absent → no findings.
	if got := lintRelationArray("00001-a", "title: x\n", "supersedes", planSupersedesRe, known); len(got) > 0 {
		t.Fatalf("absent field: %v", got)
	}
	// Self-reference → one finding.
	got := lintRelationArray("00001-a", "supersedes: [00001-a]\n", "supersedes", planSupersedesRe, known)
	if len(got) != 1 || !strings.Contains(got[0], "cannot reference the scope itself") {
		t.Fatalf("self-ref: %v", got)
	}
	// Dangling sibling → one finding.
	got = lintRelationArray("00001-a", "supersedes: [00099-missing]\n", "supersedes", planSupersedesRe, known)
	if len(got) != 1 || !strings.Contains(got[0], "does not match any scope file") {
		t.Fatalf("dangling: %v", got)
	}
}

// TestLintBidirectional covers the symmetric / asymmetric / no-link
// outcomes of the forward+back-link integrity check, without going
// through lintScopeFile so a regression here surfaces alone.
func TestLintBidirectional(t *testing.T) {
	// Symmetric → no findings.
	fwd := map[string]map[string]bool{"a": {"b": true}}
	back := map[string]map[string]bool{"b": {"a": true}}
	if got := lintBidirectional("a", fwd, back, "extends", "extended_by"); len(got) > 0 {
		t.Fatalf("symmetric: %v", got)
	}
	// Forward present, back missing → one finding.
	fwd = map[string]map[string]bool{"a": {"b": true}}
	back = map[string]map[string]bool{}
	got := lintBidirectional("a", fwd, back, "extends", "extended_by")
	if len(got) != 1 || !strings.Contains(got[0], "extended_by") {
		t.Fatalf("fwd-only: %v", got)
	}
	// Back present, forward missing → one finding.
	fwd = map[string]map[string]bool{}
	back = map[string]map[string]bool{"a": {"b": true}}
	got = lintBidirectional("a", fwd, back, "extends", "extended_by")
	if len(got) != 1 || !strings.Contains(got[0], "extends") {
		t.Fatalf("back-only: %v", got)
	}
}

// TestLintTitle pins the parsed-title + finding contract directly:
// missing → finding, empty quoted → finding, valid quoted → trimmed.
func TestLintTitle(t *testing.T) {
	got, findings := lintTitle("status: valid\n")
	if got != "" || len(findings) != 1 {
		t.Fatalf("missing: %q %v", got, findings)
	}
	got, findings = lintTitle(`title: ""` + "\n")
	if got != "" || len(findings) != 1 {
		t.Fatalf("empty quoted: %q %v", got, findings)
	}
	got, findings = lintTitle(`title: "Quoted Title"` + "\n")
	if got != "Quoted Title" || len(findings) > 0 {
		t.Fatalf("quoted: %q %v", got, findings)
	}
	got, findings = lintTitle("title: Bare Title\n")
	if got != "Bare Title" || len(findings) > 0 {
		t.Fatalf("bare: %q %v", got, findings)
	}
}

// TestLintCreated walks the three forms the field validator cares
// about: missing, present-but-malformed, valid ISO-8601-UTC.
func TestLintCreated(t *testing.T) {
	if got := lintCreated("title: x\n"); len(got) != 1 {
		t.Fatalf("missing: %v", got)
	}
	if got := lintCreated("created: 2026-05-23\n"); len(got) != 1 {
		t.Fatalf("date-only malformed: %v", got)
	}
	if got := lintCreated("created: 2026-05-23T14:30:00Z\n"); len(got) > 0 {
		t.Fatalf("valid: %v", got)
	}
}

// TestLintFrontmatterOrder covers the "title first, created last"
// invariant directly so a position-only regression doesn't mix with
// the content-validity findings tested elsewhere.
func TestLintFrontmatterOrder(t *testing.T) {
	good := "title: a\nstatus: valid\nsystems: [a]\ncreated: 2026-05-23T14:30:00Z"
	if got := lintFrontmatterOrder(good); len(got) > 0 {
		t.Fatalf("good order: %v", got)
	}
	bad := "status: valid\ntitle: a\nsystems: [a]\ncreated: 2026-05-23T14:30:00Z"
	got := lintFrontmatterOrder(bad)
	if len(got) != 1 || !strings.Contains(got[0], "title") {
		t.Fatalf("title not first: %v", got)
	}
	bad = "title: a\nstatus: valid\ncreated: 2026-05-23T14:30:00Z\nsystems: [a]"
	got = lintFrontmatterOrder(bad)
	if len(got) != 1 || !strings.Contains(got[0], "created") {
		t.Fatalf("created not last: %v", got)
	}
}

// TestLintFilenameMatchesTitle covers the title↔filename drift check
// and the early-out conditions: empty title (upstream already flagged),
// non-conforming filename (upstream already flagged), unsluggable title.
func TestLintFilenameMatchesTitle(t *testing.T) {
	if got := lintFilenameMatchesTitle("00001-foo.md", 5, ""); len(got) > 0 {
		t.Fatalf("empty title early-out: %v", got)
	}
	if got := lintFilenameMatchesTitle("garbage", 5, "Some Title"); len(got) > 0 {
		t.Fatalf("non-conforming filename early-out: %v", got)
	}
	if got := lintFilenameMatchesTitle("00001-foo.md", 5, "Foo"); len(got) > 0 {
		t.Fatalf("matching: %v", got)
	}
	got := lintFilenameMatchesTitle("00001-foo.md", 5, "Bar")
	if len(got) != 1 || !strings.Contains(got[0], "does not match") {
		t.Fatalf("mismatch: %v", got)
	}
	got = lintFilenameMatchesTitle("00001-foo.md", 5, "!!!")
	if len(got) != 1 || !strings.Contains(got[0], "no slug-able") {
		t.Fatalf("unsluggable title: %v", got)
	}
}

// TestLintRequiredSections asserts the presence-only check for the
// three H2 sections — order and content are out of scope.
func TestLintRequiredSections(t *testing.T) {
	body := "## Goal\ng\n## Approach\na\n## Tasks\nt\n"
	if got := lintRequiredSections(body); len(got) > 0 {
		t.Fatalf("all present: %v", got)
	}
	body = "## Goal\ng\n## Approach\na\n"
	got := lintRequiredSections(body)
	if len(got) != 1 || !strings.Contains(got[0], "## Tasks") {
		t.Fatalf("missing tasks: %v", got)
	}
	if got := lintRequiredSections(""); len(got) != 3 {
		t.Fatalf("empty body: %v", got)
	}
}

// TestLintEarsTasks pins the two invariants: every subject must resolve
// to a registry entry, AND the resolved-id set must equal the declared-
// systems set. Both directions of the set-equality check (extra vs.
// missing) are covered.
func TestLintEarsTasks(t *testing.T) {
	reg := newRegistry("auth", "Auth Service", "billing", "Billing Service")
	body := "## Tasks\n- [ ] The Auth Service shall do.\n- [ ] The Billing Service shall do.\n"
	if got := lintEarsTasks(body, []string{"auth", "billing"}, reg, fixtureRegistryPath); len(got) > 0 {
		t.Fatalf("symmetric: %v", got)
	}
	// Subject unknown → one finding per unknown.
	body = "## Tasks\n- [ ] The Mystery Service shall do.\n"
	got := lintEarsTasks(body, []string{"auth"}, reg, fixtureRegistryPath)
	if len(got) == 0 || !strings.Contains(got[0], "Mystery Service") {
		t.Fatalf("unknown subject: %v", got)
	}
	// Declared system not used in any task → one finding.
	body = "## Tasks\n- [ ] The Auth Service shall do.\n"
	got = lintEarsTasks(body, []string{"auth", "billing"}, reg, fixtureRegistryPath)
	var sawMissing bool
	for _, f := range got {
		if strings.Contains(f, "not used in any EARS task") {
			sawMissing = true
		}
	}
	if !sawMissing {
		t.Fatalf("declared-not-used: %v", got)
	}
}

// TestInlineSlugSet exercises the small helper that backs scanPlansRelations.
// Empty input must return nil (not an empty map) so a missing field at
// the call site stays distinguishable from "field present but empty".
func TestInlineSlugSet(t *testing.T) {
	if got := inlineSlugSet(""); got != nil {
		t.Fatalf("empty: %v", got)
	}
	got := inlineSlugSet("00001-a, 00002-b, \"00003-c\"")
	if len(got) != 3 || !got["00001-a"] || !got["00002-b"] || !got["00003-c"] {
		t.Fatalf("3-element: %v", got)
	}
}

// TestSetRegistryField pins the key dispatch (id, name, brief,
// other-ignored) and the value normalization (quote-strip +
// whitespace-trim) that the hand-rolled parser relies on for both
// single-line and continuation forms.
func TestSetRegistryField(t *testing.T) {
	var id, name, brief string
	setRegistryField(&id, &name, &brief, "id", `"auth-service"`)
	setRegistryField(&id, &name, &brief, "name", `   Auth Service   `)
	setRegistryField(&id, &name, &brief, "brief", `"OAuth and session management."`)
	if id != "auth-service" || name != "Auth Service" || brief != "OAuth and session management." {
		t.Fatalf("got id=%q name=%q brief=%q", id, name, brief)
	}
	// Unknown keys are silently dropped.
	setRegistryField(&id, &name, &brief, "unknown", "ignored")
	if id != "auth-service" || name != "Auth Service" || brief != "OAuth and session management." {
		t.Fatalf("unknown-key mutated state: id=%q name=%q brief=%q", id, name, brief)
	}
}

// ---------- runScopes* entry-point helpers (planNextPrefix / planList / planLint / planSlugify) ----------
//
// The four scopes-subcommand entry points each have a thin os.Exit
// wrapper around a pure helper. These tests drive the helpers directly
// against captured stdout/stderr buffers so the full flow — flag-set
// parsing, project marker check, output format, exit code — is unit-covered.

// freshProjectAndChdir seeds an initialized .stax/ scaffold inside a
// temp dir, chdirs into it, and returns the dir. Shared between the four
// entry-point test groups so each test stays short.
func freshProjectAndChdir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	seedProject(t, dir)
	chdir(t, dir)
	return dir
}

// seedListScope writes a scope-format file at <dir>/<name> with minimal
// frontmatter (status + single-system) + a body line. Distinct from the
// pre-existing writeScopeFile helper (which takes a raw frontmatter
// string for the lint-focused tests) — the entry-point tests just need
// to list / next-prefix-walk these files, not lint them.
func seedListScope(t *testing.T, dir, name, status, system, body string) string {
	t.Helper()
	content := fmt.Sprintf("---\nstatus: %s\nsystems: [%s]\n---\n%s\n", status, system, body)
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
		t.Fatalf("write scope %s: %v", name, err)
	}
	return strings.TrimSuffix(name, scopeFileExt)
}

// ---- planNextPrefix ----

func TestScopeNextPrefix_Happy(t *testing.T) {
	dir := freshProjectAndChdir(t)
	staxPath := filepath.Join(dir, staxDir)
	seedListScope(t, staxPath, "0001-a.md", "valid", "auth", "x")
	seedListScope(t, staxPath, "0003-c.md", "valid", "auth", "x")
	var out, errb bytes.Buffer
	if rc := planNextPrefix(nil, staxDir, &out, &errb); rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
	if out.String() != "0004\n" {
		t.Fatalf("stdout = %q, want %q", out.String(), "0004\n")
	}
}

func TestScopeNextPrefix_NotProject(t *testing.T) {
	chdir(t, t.TempDir())
	var out, errb bytes.Buffer
	rc := planNextPrefix(nil, staxDir, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "not a stax project") {
		t.Fatalf("missing banner in stderr: %q", errb.String())
	}
}

func TestScopeNextPrefix_StrayArg(t *testing.T) {
	freshProjectAndChdir(t)
	var out, errb bytes.Buffer
	rc := planNextPrefix([]string{"unexpected"}, staxDir, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "takes no arguments") {
		t.Fatalf("diagnostic missing: %q", errb.String())
	}
}

func TestScopeNextPrefix_RespectsPrefixWidth(t *testing.T) {
	dir := freshProjectAndChdir(t)
	// Overwrite the seed-empty lock with a width=6 pin.
	lock := filepath.Join(dir, staxDir, staxLockFile)
	if err := os.WriteFile(lock, []byte(`{"prefix_width":6}`), 0o600); err != nil {
		t.Fatalf("write lock: %v", err)
	}
	var out, errb bytes.Buffer
	if rc := planNextPrefix(nil, staxDir, &out, &errb); rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
	if out.String() != "000001\n" {
		t.Fatalf("stdout = %q, want 000001\\n (6-wide first prefix)", out.String())
	}
}

// ---- planList ----

func TestScopeList_HappyPath(t *testing.T) {
	dir := freshProjectAndChdir(t)
	staxPath := filepath.Join(dir, staxDir)
	seedListScope(t, staxPath, "0001-a.md", "valid", "auth", "x")
	seedListScope(t, staxPath, "0002-b.md", "deprecated", "billing", "x")
	var out, errb bytes.Buffer
	if rc := planList(nil, staxDir, &out, &errb); rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
	// Default --order=desc → 0002 before 0001.
	want := "0002-b\tdeprecated\tbilling\n0001-a\tvalid\tauth\n"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q", out.String(), want)
	}
}

func TestScopeList_NotProject(t *testing.T) {
	chdir(t, t.TempDir())
	var out, errb bytes.Buffer
	rc := planList(nil, staxDir, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "not a stax project") {
		t.Fatalf("missing banner: %q", errb.String())
	}
}

func TestScopeList_StrayArg(t *testing.T) {
	freshProjectAndChdir(t)
	var out, errb bytes.Buffer
	rc := planList([]string{"unexpected"}, staxDir, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "no positional arguments") {
		t.Fatalf("diagnostic missing: %q", errb.String())
	}
}

func TestScopeList_BadOrder(t *testing.T) {
	freshProjectAndChdir(t)
	var out, errb bytes.Buffer
	rc := planList([]string{"--order", "garbage"}, staxDir, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), `--order must be "asc" or "desc"`) {
		t.Fatalf("diagnostic missing: %q", errb.String())
	}
}

func TestScopeList_StatusFilter(t *testing.T) {
	dir := freshProjectAndChdir(t)
	staxPath := filepath.Join(dir, staxDir)
	seedListScope(t, staxPath, "0001-a.md", "valid", "auth", "x")
	seedListScope(t, staxPath, "0002-b.md", "deprecated", "auth", "x")
	seedListScope(t, staxPath, "0003-c.md", "valid", "auth", "x")
	var out, errb bytes.Buffer
	if rc := planList([]string{"--status", "valid"}, staxDir, &out, &errb); rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
	// Default desc: 0003 then 0001, deprecated 0002 dropped.
	want := "0003-c\tvalid\tauth\n0001-a\tvalid\tauth\n"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q", out.String(), want)
	}
}

// ---- planLint ----

func TestScopeLint_AllPass(t *testing.T) {
	dir := freshProjectAndChdir(t)
	staxPath := filepath.Join(dir, staxDir)
	// Registry with one system so the EARS-subject check resolves cleanly.
	if err := os.WriteFile(filepath.Join(staxPath, staxSystemsFile),
		[]byte("systems:\n  - id: auth\n    name: Auth Service\n"), 0o600); err != nil {
		t.Fatalf("write registry: %v", err)
	}
	scopeBody := "---\ntitle: a\nstatus: valid\nsystems: [auth]\ncreated: 2026-05-23T14:30:00Z\n---\n\n## Goal\ng\n\n## Approach\nA\n\n## Tasks\n- [ ] The Auth Service shall do.\n"
	if err := os.WriteFile(filepath.Join(staxPath, "0001-a.md"), []byte(scopeBody), 0o600); err != nil {
		t.Fatalf("write scope: %v", err)
	}
	var out, errb bytes.Buffer
	if rc := planLint(nil, staxDir, &out, &errb); rc != 0 {
		t.Fatalf("rc=%d stdout=%q stderr=%q", rc, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "0001-a.md: ok") {
		t.Fatalf("expected per-file ok in stdout: %q", out.String())
	}
	if !strings.Contains(errb.String(), "1 ok, 0 failed") {
		t.Fatalf("summary line missing in stderr: %q", errb.String())
	}
}

func TestScopeLint_OneFail(t *testing.T) {
	dir := freshProjectAndChdir(t)
	staxPath := filepath.Join(dir, staxDir)
	// Scope without frontmatter → splitFrontmatter stops; lintScopeFile
	// returns ≥1 finding.
	if err := os.WriteFile(filepath.Join(staxPath, "0001-broken.md"), []byte("no frontmatter\n"), 0o600); err != nil {
		t.Fatalf("write scope: %v", err)
	}
	var out, errb bytes.Buffer
	if rc := planLint(nil, staxDir, &out, &errb); rc != 1 {
		t.Fatalf("rc=%d, want 1", rc)
	}
	if !strings.Contains(out.String(), "0001-broken.md:") {
		t.Fatalf("expected finding on stdout: %q", out.String())
	}
	if !strings.Contains(errb.String(), "0 ok, 1 failed") {
		t.Fatalf("summary missing in stderr: %q", errb.String())
	}
}

func TestScopeLint_EmptyProject(t *testing.T) {
	freshProjectAndChdir(t)
	var out, errb bytes.Buffer
	if rc := planLint(nil, staxDir, &out, &errb); rc != 0 {
		t.Fatalf("rc=%d, want 0 on empty project", rc)
	}
	if !strings.Contains(errb.String(), "0 ok, 0 failed") {
		t.Fatalf("summary line missing: %q", errb.String())
	}
}

func TestScopeLint_NotProject(t *testing.T) {
	chdir(t, t.TempDir())
	var out, errb bytes.Buffer
	rc := planLint(nil, staxDir, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "not a stax project") {
		t.Fatalf("missing banner: %q", errb.String())
	}
}

func TestScopeLint_StrayArg(t *testing.T) {
	freshProjectAndChdir(t)
	var out, errb bytes.Buffer
	rc := planLint([]string{"unexpected"}, staxDir, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "takes no arguments") {
		t.Fatalf("diagnostic missing: %q", errb.String())
	}
}

// ---- planSlugify ----

func TestScopeSlugify_Happy(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := planSlugify([]string{"Hello World"}, &out, &errb); rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	if out.String() != "hello-world\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestScopeSlugify_Help(t *testing.T) {
	for _, flag := range []string{"-h", "--help"} {
		var out, errb bytes.Buffer
		if rc := planSlugify([]string{flag}, &out, &errb); rc != 0 {
			t.Fatalf("%s: rc=%d want 0", flag, rc)
		}
		if out.String() != "" {
			t.Fatalf("%s: stdout = %q, want empty", flag, out.String())
		}
		if !strings.Contains(errb.String(), "Usage:") {
			t.Fatalf("%s: usage missing on stderr: %q", flag, errb.String())
		}
	}
}

func TestScopeSlugify_NoArgs(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := planSlugify(nil, &out, &errb); rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "Usage:") {
		t.Fatalf("usage missing: %q", errb.String())
	}
}

func TestScopeSlugify_TooManyArgs(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := planSlugify([]string{"one", "two"}, &out, &errb); rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
}

func TestScopeSlugify_LegacyDoubleDash(t *testing.T) {
	// `--` is stripped; the next arg becomes the title even if it starts
	// with dashes — that's the historical separator semantics we keep
	// working for older scripted callers.
	var out, errb bytes.Buffer
	if rc := planSlugify([]string{"--", "--Draft Note"}, &out, &errb); rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
	if out.String() != "draft-note\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestScopeSlugify_Unsluggable(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := planSlugify([]string{"!!!"}, &out, &errb); rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "no slug-able characters") {
		t.Fatalf("diagnostic missing: %q", errb.String())
	}
}

// ---- --cwd on every scopes subcommand ----

// TestScopeNextPrefix_CwdFlag pins the project-marker check + scan path
// against a target directory passed via --cwd. Start in an unscaffolded
// outer dir (would normally fail the marker check) and ensure --cwd
// shifts the check onto an initialized sibling project.
func TestScopeNextPrefix_CwdFlag(t *testing.T) {
	outer := t.TempDir()
	chdir(t, outer)
	target := t.TempDir()
	seedProject(t, target)
	// Drop one existing scope inside the target so next-prefix returns
	// something more interesting than "0001".
	if err := os.WriteFile(filepath.Join(target, staxDir, "0007-existing"+scopeFileExt), nil, 0o600); err != nil {
		t.Fatalf("seed scope: %v", err)
	}
	var out, errb bytes.Buffer
	rc := planNextPrefix([]string{"--cwd", target}, staxDir, &out, &errb)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
	if out.String() != "0008\n" {
		t.Fatalf("stdout = %q, want 0008\\n (scan must run inside --cwd target)", out.String())
	}
}

// TestScopeNextPrefix_CwdMissing pins the --cwd validation: a missing
// path errors out with rc=2 (usage error) and a --cwd-attributed
// diagnostic, BEFORE the project-marker check fires (which would
// otherwise produce a misleading "not a stax project" banner).
func TestScopeNextPrefix_CwdMissing(t *testing.T) {
	chdir(t, t.TempDir())
	missing := filepath.Join(t.TempDir(), "no-such-dir")
	var out, errb bytes.Buffer
	rc := planNextPrefix([]string{"--cwd", missing}, staxDir, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "--cwd") {
		t.Fatalf("diagnostic must mention --cwd: %q", errb.String())
	}
	if strings.Contains(errb.String(), "not a stax project") {
		t.Fatalf("diagnostic should NOT mention the marker check: %q", errb.String())
	}
}

// TestScopeList_CwdFlag is the listing analog: chdir away from the
// project, point --cwd at it, and verify the rows come from the target.
func TestScopeList_CwdFlag(t *testing.T) {
	chdir(t, t.TempDir())
	target := t.TempDir()
	seedProject(t, target)
	staxPath := filepath.Join(target, staxDir)
	seedListScope(t, staxPath, "0001-a"+scopeFileExt, "valid", "auth", "x")
	seedListScope(t, staxPath, "0002-b"+scopeFileExt, "deprecated", "billing", "x")
	var out, errb bytes.Buffer
	rc := planList([]string{"--cwd", target}, staxDir, &out, &errb)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
	// Default --order=desc → 0002 first.
	want := "0002-b\tdeprecated\tbilling\n0001-a\tvalid\tauth\n"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q", out.String(), want)
	}
}

// TestScopeLint_CwdFlag pins lint's --cwd path: an initialized project
// under target is linted even though the test process started in an
// unscaffolded outer dir.
func TestScopeLint_CwdFlag(t *testing.T) {
	chdir(t, t.TempDir())
	target := t.TempDir()
	seedProject(t, target)
	staxPath := filepath.Join(target, staxDir)
	if err := os.WriteFile(filepath.Join(staxPath, staxSystemsFile),
		[]byte("systems:\n  - id: auth\n    name: Auth Service\n"), 0o600); err != nil {
		t.Fatalf("write registry: %v", err)
	}
	scopeBody := "---\ntitle: a\nstatus: valid\nsystems: [auth]\ncreated: 2026-05-23T14:30:00Z\n---\n\n## Goal\ng\n\n## Approach\nA\n\n## Tasks\n- [ ] The Auth Service shall do.\n"
	if err := os.WriteFile(filepath.Join(staxPath, "0001-a"+scopeFileExt), []byte(scopeBody), 0o600); err != nil {
		t.Fatalf("write scope: %v", err)
	}
	var out, errb bytes.Buffer
	rc := planLint([]string{"--cwd", target}, staxDir, &out, &errb)
	if rc != 0 {
		t.Fatalf("rc=%d stdout=%q stderr=%q", rc, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "0001-a"+scopeFileExt+": ok") {
		t.Fatalf("expected per-file ok in stdout: %q", out.String())
	}
}

// TestScopeSlugify_CwdFlag exercises both `--cwd PATH` and `--cwd=PATH`
// forms on slugify. Slugify itself is cwd-independent — the test only
// proves the flag is accepted without disrupting the title positional.
func TestScopeSlugify_CwdFlag(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	other := t.TempDir()
	cases := []struct {
		name string
		args []string
	}{
		{"separate-value", []string{"--cwd", other, "Hello World"}},
		{"equals-value", []string{"--cwd=" + other, "Hello World"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			chdir(t, dir)
			var out, errb bytes.Buffer
			if rc := planSlugify(c.args, &out, &errb); rc != 0 {
				t.Fatalf("rc=%d stderr=%q", rc, errb.String())
			}
			if out.String() != "hello-world\n" {
				t.Fatalf("stdout = %q, want hello-world\\n", out.String())
			}
		})
	}
}

// TestScopeSlugify_CwdMissingValue rejects a bare `--cwd` with no value.
// Pin matches the hand-parsed validator path (slugify can't use
// flag.Parse because its title positional may legitimately start with
// `-`).
func TestScopeSlugify_CwdMissingValue(t *testing.T) {
	var out, errb bytes.Buffer
	rc := planSlugify([]string{"--cwd"}, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "--cwd requires a value") {
		t.Fatalf("diagnostic missing: %q", errb.String())
	}
}

// TestScopeSlugify_CwdRejectsMissingPath pins the validation chain past
// the flag-consumer: a syntactically OK `--cwd <path>` whose target
// doesn't exist still surfaces as an error attributed to --cwd, before
// the title positional is examined.
func TestScopeSlugify_CwdRejectsMissingPath(t *testing.T) {
	chdir(t, t.TempDir())
	missing := filepath.Join(t.TempDir(), "no-such-dir")
	var out, errb bytes.Buffer
	rc := planSlugify([]string{"--cwd", missing, "anything"}, &out, &errb)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "--cwd") {
		t.Fatalf("diagnostic must mention --cwd: %q", errb.String())
	}
}

// TestExtractCwdFromHead drives the hand-parsed --cwd consumer used by
// slugify. Three cases: separate value, =value form, no flag at all.
// The "no flag" case must leave rest untouched even when its first
// element looks flag-ish (a leading `-`) — this is what protects
// slugify's right to receive titles that start with dashes.
func TestExtractCwdFromHead(t *testing.T) {
	var errb bytes.Buffer
	cases := []struct {
		name    string
		args    []string
		wantCwd string
		wantRst []string
		wantOK  bool
	}{
		{"absent", []string{"Hello"}, "", []string{"Hello"}, true},
		{"separate", []string{"--cwd", "/tmp/x", "Hello"}, "/tmp/x", []string{"Hello"}, true},
		{"equals", []string{"--cwd=/tmp/x", "Hello"}, "/tmp/x", []string{"Hello"}, true},
		{"dash-title", []string{"---draft"}, "", []string{"---draft"}, true},
		{"last-wins", []string{"--cwd", "/a", "--cwd=/b", "Hello"}, "/b", []string{"Hello"}, true},
		{"missing-value", []string{"--cwd"}, "", nil, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			errb.Reset()
			cwd, rest, ok := extractCwdFromHead(c.args, &errb)
			if ok != c.wantOK {
				t.Fatalf("ok=%v want %v (stderr=%q)", ok, c.wantOK, errb.String())
			}
			if cwd != c.wantCwd {
				t.Fatalf("cwd=%q want %q", cwd, c.wantCwd)
			}
			if strings.Join(rest, "|") != strings.Join(c.wantRst, "|") {
				t.Fatalf("rest=%v want %v", rest, c.wantRst)
			}
		})
	}
}
