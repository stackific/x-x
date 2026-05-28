// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// runPlans dispatches `stax plans <subcommand>`. Future plan-tooling commands
// (e.g. `lint`) can be added here without restructuring, the same way
// `runSkills` is structured.
func runPlans(args []string) {
	if len(args) == 0 {
		printPlansUsage(os.Stderr)
		os.Exit(2)
	}
	switch args[0] {
	case "next-prefix":
		runPlansNextPrefix(args[1:])
	case "list":
		runPlansList(args[1:])
	case "lint":
		runPlansLint(args[1:])
	case "slugify":
		runPlansSlugify(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown plans subcommand: %s\n", args[0])
		printPlansUsage(os.Stderr)
		os.Exit(2)
	}
}

// printPlansUsage writes the `stax plans` help block to w. Mirrors the
// printSkillsUsage structure (one-line subcommand summaries) so the two help
// surfaces stay visually aligned; both ride on a writer parameter rather
// than os.Stderr directly so future `--help` paths can redirect to stdout.
func printPlansUsage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage: stax plans <subcommand>")
	_, _ = fmt.Fprintln(w, "  next-prefix   Print the next unused zero-padded plan prefix")
	_, _ = fmt.Fprintln(w, "  list          List plans with slug, status, and declared systems")
	_, _ = fmt.Fprintln(w, "  lint          Validate every plan file against the project schema")
	_, _ = fmt.Fprintln(w, "  slugify       Print the kebab-case slug for a plan title")
}

// runPlansNextPrefix prints the next available zero-padded plan prefix in
// staxDir (the standard ".stax" under cwd). Takes no arguments — the
// directory is not user-configurable; staxDir is the single source of truth.
//
// Prefix width is read from <staxDir>/<staxLockFile> (JSON), falling
// back to defaultPrefixWidth when the lock file is missing or malformed.
// Missing staxDir is treated as empty (next prefix = 1), so the command is
// safe to run before `stax init` has seeded the scaffold.
func runPlansNextPrefix(args []string) {
	os.Exit(planNextPrefix(args, staxDir, os.Stdout, os.Stderr))
}

// planNextPrefix is the testable body of runPlansNextPrefix: flag-set
// parsing, project marker check, format, write — all without touching os.Exit
// directly. Returns the desired exit code (0 happy, 2 usage error /
// not-a-project). Pulled out so unit tests can drive the full flow
// (argument rejection, project-marker-check banner, zero-pad format) without
// shelling out a subprocess.
func planNextPrefix(args []string, staxDir string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("plans next-prefix", flag.ContinueOnError)
	fs.SetOutput(stderr)
	cwdFlag := fs.String("cwd", "", "change to this directory before running (like git -C)")
	fs.Usage = func() {
		_, _ = fmt.Fprintln(stderr, "Usage: stax plans next-prefix [--cwd PATH]")
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		_, _ = fmt.Fprintf(stderr, "stax plans next-prefix takes no arguments (got %q)\n", fs.Arg(0))
		return 2
	}
	if err := applyCwd(*cwdFlag); err != nil {
		_, _ = fmt.Fprintln(stderr, "error:", err)
		return 2
	}
	if err := checkProject(); err != nil {
		_, _ = fmt.Fprintln(stderr, notProjectBanner)
		return 2
	}
	width := loadPrefixWidth(staxDir)
	next := scanHighestPrefix(staxDir, width) + 1
	_, _ = fmt.Fprintf(stdout, "%0*d\n", width, next)
	// Anonymous-usage ping on the success path.
	track("plans_next_prefix", telemetryEvent{
		"prefix": fmt.Sprintf("%0*d", width, next),
	})
	flushTelemetry()
	return 0
}

// loadPrefixWidth reads prefix_width from <staxDir>/<staxLockFile>.
// Returns defaultPrefixWidth on any read/parse failure so the command is
// usable before `stax init` has seeded the lock file.
func loadPrefixWidth(staxDir string) int {
	data, err := os.ReadFile(filepath.Join(staxDir, staxLockFile)) // #nosec G304 -- staxDir is a CLI arg, path is project-local.
	if err != nil {
		return defaultPrefixWidth
	}
	var cfg struct {
		PrefixWidth int `json:"prefix_width"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil || cfg.PrefixWidth <= 0 {
		return defaultPrefixWidth
	}
	return cfg.PrefixWidth
}

// scanHighestPrefix returns the largest numeric prefix found among entry
// names in staxDir whose name pattern matches `<width digits>-<rest>.md` —
// the same filename pattern listPlans accepts. Anchoring on `-` and the
// `.md` extension (not just `\d{width}`) keeps next-prefix consistent
// with what list / lint will recognize: a 5-digit-prefixed file when
// width=4 doesn't match either pattern and must not be counted, otherwise
// next-prefix would hand out numbers based on files list / lint silently
// ignore.
func scanHighestPrefix(staxDir string, width int) int {
	entries, err := os.ReadDir(staxDir)
	if err != nil {
		return 0
	}
	re := regexp.MustCompile(fmt.Sprintf(`^(\d{%d})-.+%s$`, width, regexp.QuoteMeta(planFileExt)))
	highest := 0
	for _, e := range entries {
		m := re.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		n, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		if n > highest {
			highest = n
		}
	}
	return highest
}

// runPlansList prints one tab-separated row per plan in staxDir whose
// filename matches `<prefix-digits>-<slug>.md`. Each row is
// `<slug>\t<status>\t<sys1>,<sys2>,...`. Flags:
//
//	--status NAME[,NAME...]            repeatable; keeps only matching statuses
//	--system ID                        repeatable; OR semantics; matches the
//	                                   kebab-case `id:` values that plans carry
//	                                   in their frontmatter `systems:` array
//	--order asc|desc                   prefix sort direction (default desc = latest first)
//	--overflow-keywords TERM[,...]     case-insensitive substring(s) (OR); engages
//	                                   only when the post-filter row count exceeds
//	                                   plansListOverflowThreshold (see constants.go)
//
// Files matching the filename pattern but missing frontmatter, `status:`,
// or `systems:` produce stderr warnings and are skipped. Missing staxDir
// is treated as empty (no rows, no error) so the command is safe to run
// before `stax init` has seeded the scaffold.
func runPlansList(args []string) {
	os.Exit(planList(args, staxDir, os.Stdout, os.Stderr))
}

// planList is the testable body of runPlansList. Same exit-code contract
// as the wrapper (0 happy, 1 listPlans IO error, 2 usage / not-a-project
// / bad --order). Pulled out so the filter chain + sort + overflow path
// can be exercised end-to-end at unit level — the e2e suites cover the
// same surface but a unit test fails faster on a contract regression.
func planList(args []string, staxDir string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("plans list", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var statusFlag, systemFlag, keywordsFlag stringSliceFlag
	orderFlag := fs.String("order", "desc", "sort by prefix: asc|desc (default desc = latest first)")
	cwdFlag := fs.String("cwd", "", "change to this directory before running (like git -C)")
	fs.Var(&statusFlag, "status", "keep only plans whose status matches (repeatable, comma-separated)")
	fs.Var(&systemFlag, "system", "keep only plans whose systems contain this id (repeatable; OR semantics; matches the kebab `id:` from _data_systems.yaml)")
	fs.Var(&keywordsFlag, "overflow-keywords", "case-insensitive substring(s) narrowing the output when the post-filter count exceeds plansListOverflowThreshold (repeatable; OR semantics; matched against plan body only)")
	fs.Usage = func() {
		_, _ = fmt.Fprintln(stderr, "Usage: stax plans list [--status NAME[,NAME...]] [--system ID] [--order asc|desc] [--overflow-keywords PATTERN[,PATTERN...]] [--cwd PATH]")
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		_, _ = fmt.Fprintf(stderr, "stax plans list takes no positional arguments (got %q)\n", fs.Arg(0))
		return 2
	}
	if err := applyCwd(*cwdFlag); err != nil {
		_, _ = fmt.Fprintln(stderr, "error:", err)
		return 2
	}
	if err := checkProject(); err != nil {
		_, _ = fmt.Fprintln(stderr, notProjectBanner)
		return 2
	}

	order, err := parseOrder(*orderFlag)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "stax plans list: %v\n", err)
		return 2
	}
	keywords := normalizeKeywords(keywordsFlag)
	statusSet := toFilterSet(statusFlag)
	systemSet := toFilterSet(systemFlag)

	width := loadPrefixWidth(staxDir)
	rows, err := listPlans(staxDir, width, stderr)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "stax plans list: %v\n", err)
		return 1
	}

	// Apply --status / --system filters first so the overflow trigger
	// keys off the post-filter count (matching the user-visible result).
	filtered := filterPlanRows(rows, statusSet, systemSet)
	sortPlanRows(filtered, order)
	filtered = applyOverflowNarrow(filtered, keywords, staxDir, plansListOverflowThreshold)

	for _, r := range filtered {
		_, _ = fmt.Fprintf(stdout, "%s\t%s\t%s\n", r.slug, r.status, strings.Join(r.systems, ","))
	}
	return 0
}

// plansListOrder enumerates the two values --order accepts. Defined as a
// typed int (not strings) so the sort-by-value switch in sortPlanRows
// can't be invoked with an arbitrary, unvalidated string.
type plansListOrder int

const (
	orderAsc  plansListOrder = 1
	orderDesc plansListOrder = 2
)

// parseOrder validates the --order CLI value and returns its enum.
func parseOrder(s string) (plansListOrder, error) {
	switch s {
	case "asc":
		return orderAsc, nil
	case "desc":
		return orderDesc, nil
	default:
		return 0, fmt.Errorf("--order must be \"asc\" or \"desc\", got %q", s)
	}
}

// sortPlanRows sorts rows in-place by slug — which, because slugs carry
// the zero-padded numeric prefix, equals prefix-numeric order. Ascending
// or descending per the order argument; desc is the CLI default (latest
// first).
func sortPlanRows(rows []planRow, order plansListOrder) {
	if order == orderAsc {
		sort.Slice(rows, func(i, j int) bool { return rows[i].slug < rows[j].slug })
		return
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].slug > rows[j].slug })
}

// normalizeKeywords lowercases each --overflow-keywords token and drops
// empties. Returning nil on empty input lets the caller use len()==0 to
// mean "no narrowing requested." Lowercasing once here keeps the
// per-row match in applyOverflowNarrow a single ASCII-lowercase compare.
func normalizeKeywords(tokens []string) []string {
	if len(tokens) == 0 {
		return nil
	}
	out := make([]string, 0, len(tokens))
	for _, t := range tokens {
		t = strings.ToLower(t)
		if t != "" {
			out = append(out, t)
		}
	}
	return out
}

// applyOverflowNarrow optionally narrows `rows` using --overflow-keywords.
// The narrow engages only when:
//   - len(rows) exceeds threshold, AND
//   - the caller passed at least one keyword.
//
// Match semantics: case-insensitive literal substring against the plan
// body — no regex, no word boundary. A plan matches if its body contains
// any of the keywords (OR across keywords).
//
// Behavior in the engaged path:
//   - ≥1 row's body contains ≥1 keyword → return matched rows
//     (preserving the caller's sort order).
//   - 0 rows match → return rows[:threshold] (top N in sort order),
//     so the caller still gets a workable summary instead of an empty
//     result.
//
// Otherwise rows are returned unchanged.
func applyOverflowNarrow(rows []planRow, keywords []string, staxDir string, threshold int) []planRow {
	if len(rows) <= threshold || len(keywords) == 0 {
		return rows
	}
	matched := make([]planRow, 0, len(rows))
	for _, r := range rows {
		body, ok := readPlanBody(filepath.Join(staxDir, r.slug+planFileExt))
		if !ok {
			continue
		}
		lower := strings.ToLower(body)
		for _, kw := range keywords {
			if strings.Contains(lower, kw) {
				matched = append(matched, r)
				break
			}
		}
	}
	if len(matched) > 0 {
		return matched
	}
	return rows[:threshold]
}

// readPlanBody returns the post-frontmatter body of the plan file at
// path. (false) on missing/unreadable/malformed-frontmatter files so the
// caller can skip them; lintPlanFile surfaces those as per-file findings
// on its own pass.
func readPlanBody(path string) (string, bool) {
	data, err := os.ReadFile(path) // #nosec G304 -- path is composed from a CLI-driven staxDir + slug.
	if err != nil {
		return "", false
	}
	_, body, _, stop := splitFrontmatter(string(data))
	if stop {
		return "", false
	}
	return body, true
}

// stringSliceFlag is a flag.Value that accumulates values across repeated
// occurrences AND splits comma-separated input — so `--status valid
// --status superseded` and `--status valid,superseded` are equivalent.
type stringSliceFlag []string

// String renders the accumulated values as a comma list — flag's default
// help text uses this, so the format mirrors what users would pass on
// the command line.
func (s *stringSliceFlag) String() string { return strings.Join(*s, ",") }

// Set is invoked once per `--<flag> <value>` occurrence. It splits on
// commas, trims whitespace per token, and appends non-empty tokens to
// the underlying slice.
func (s *stringSliceFlag) Set(v string) error {
	for _, tok := range strings.Split(v, ",") {
		tok = strings.TrimSpace(tok)
		if tok != "" {
			*s = append(*s, tok)
		}
	}
	return nil
}

// toFilterSet collapses a (possibly empty) string slice into a set for
// O(1) membership checks in the row-emission loop.
func toFilterSet(vs []string) map[string]bool {
	if len(vs) == 0 {
		return nil
	}
	set := make(map[string]bool, len(vs))
	for _, v := range vs {
		set[v] = true
	}
	return set
}

// anySystemMatches reports whether any element of haystack appears in
// needles. Used to implement OR semantics for the `--system` filter —
// both sides are kebab-case ids (the `id:` field from _data_systems.yaml,
// which is also what plan frontmatter `systems:` arrays carry).
func anySystemMatches(haystack []string, needles map[string]bool) bool {
	for _, h := range haystack {
		if needles[h] {
			return true
		}
	}
	return false
}

// filterPlanRows keeps only rows whose status is in statusSet AND whose
// systems intersect systemSet. Either filter is treated as "no filter"
// when its set is empty (len==0 OR nil), matching the CLI semantics where
// an absent --status / --system flag means "all". Pulled out of
// runPlansList so the filter chain is unit-testable on its own — without
// this helper the only path through status+system filtering was via the
// e2e harness.
func filterPlanRows(rows []planRow, statusSet, systemSet map[string]bool) []planRow {
	filtered := make([]planRow, 0, len(rows))
	for _, r := range rows {
		if len(statusSet) > 0 && !statusSet[r.status] {
			continue
		}
		if len(systemSet) > 0 && !anySystemMatches(r.systems, systemSet) {
			continue
		}
		filtered = append(filtered, r)
	}
	return filtered
}

// planRow is one parsed plan file ready for emission.
type planRow struct {
	slug    string
	status  string
	systems []string
}

// Frontmatter regexes — anchored multi-line. Only inline-array `systems:`
// is recognized; block form (`- entry` on subsequent lines) is rejected.
var (
	planStatusRe  = regexp.MustCompile(`(?m)^status:\s*(\S+)\s*$`)
	planSystemsRe = regexp.MustCompile(`(?m)^systems:\s*\[([^\]]*)\]\s*$`)
)

// listPlans walks staxDir, parses every file whose name matches
// `<width digits>-<anything>.md`, and returns the parsed rows in
// prefix-ascending order. Warnings for filename-matching files with
// malformed/missing frontmatter go to warnW so the caller can route them
// (CLI sends them to stderr; tests can capture them).
//
// Missing staxDir is treated as "no plans" (returns nil, nil) so callers
// don't need to special-case the pre-init state.
func listPlans(staxDir string, width int, warnW io.Writer) ([]planRow, error) {
	entries, err := os.ReadDir(staxDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}

	// `<width digits>-<at least one char><planFileExt>`. The trailing
	// extension is part of the contract enforced by `plans lint`; we match
	// the same pattern so stray docs (README.md, _data_systems.yaml) are
	// silently ignored.
	nameRe := regexp.MustCompile(fmt.Sprintf(`^\d{%d}-.+%s$`, width, regexp.QuoteMeta(planFileExt)))

	// Collect matching names first so we can sort once before parsing.
	// Sorting after parsing would still work (slugs preserve the prefix)
	// but doing it up front keeps the parse phase deterministic for tests.
	var names []string
	for _, e := range entries {
		if e.IsDir() || !nameRe.MatchString(e.Name()) {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)

	rows := make([]planRow, 0, len(names))
	for _, name := range names {
		row, ok := parsePlan(filepath.Join(staxDir, name), warnW)
		if !ok {
			continue
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// parsePlan reads one plan file and extracts (slug, status, systems).
// Returns (_, false) and emits a stderr-style warning to warnW when the
// file lacks frontmatter or is missing a required field — warn-and-skip
// so a single bad file never aborts the whole `plans list` walk.
func parsePlan(path string, warnW io.Writer) (planRow, bool) {
	data, err := os.ReadFile(path) // #nosec G304 -- path is constructed from a CLI-driven ReadDir of staxDir.
	if err != nil {
		_, _ = fmt.Fprintf(warnW, "warning: %s: %v; skipping\n", path, err)
		return planRow{}, false
	}
	text := string(data)

	// Frontmatter must open at byte 0 with `---`. Trailing CR after the
	// fence is tolerated (Windows-edited files); anything else is treated
	// as "no frontmatter".
	if !strings.HasPrefix(text, "---\n") && !strings.HasPrefix(text, "---\r\n") {
		_, _ = fmt.Fprintf(warnW, "warning: %s has no frontmatter; skipping\n", path)
		return planRow{}, false
	}
	// Look for the closing `\n---` somewhere after the opening fence. The
	// 3-byte offset skips the opening `---` so we never match it as the
	// terminator on a degenerate `---\n---` block.
	end := strings.Index(text[3:], "\n---")
	if end < 0 {
		_, _ = fmt.Fprintf(warnW, "warning: %s has unterminated frontmatter; skipping\n", path)
		return planRow{}, false
	}
	fm := text[3 : 3+end]

	statusMatch := planStatusRe.FindStringSubmatch(fm)
	if statusMatch == nil {
		_, _ = fmt.Fprintf(warnW, "warning: %s missing required `status:` field; skipping\n", path)
		return planRow{}, false
	}
	systemsMatch := planSystemsRe.FindStringSubmatch(fm)
	if systemsMatch == nil {
		_, _ = fmt.Fprintf(warnW, "warning: %s missing required `systems:` field; skipping\n", path)
		return planRow{}, false
	}

	systems := parseInlineSystems(systemsMatch[1])
	slug := strings.TrimSuffix(filepath.Base(path), planFileExt)
	return planRow{slug: slug, status: statusMatch[1], systems: systems}, true
}

// parseInlineSystems splits the body of an inline `systems: [a, b, "c"]`
// frontmatter line into trimmed, quote-stripped entries. Empty tokens
// (trailing commas, `systems: []`) are skipped.
func parseInlineSystems(raw string) []string {
	var out []string
	for _, tok := range strings.Split(raw, ",") {
		tok = strings.TrimSpace(tok)
		tok = strings.Trim(tok, "\"'")
		if tok != "" {
			out = append(out, tok)
		}
	}
	return out
}

// ---------- plans lint ----------

// Allowed plan statuses. allowedStatusesSorted is the alphabetised form
// rendered in finding messages so the user always sees the same set in
// the same order.
var (
	allowedStatuses       = map[string]bool{"valid": true, "superseded": true, "deprecated": true}
	allowedStatusesSorted = []string{"deprecated", "superseded", "valid"}
)

// Required body section headers. Presence-only check — section order is
// the author's responsibility (caught by review, not lint).
var requiredSections = []string{"## Goal", "## Approach", "## Tasks"}

// Lint-only regexes. Frontmatter status/systems regexes are reused from
// the listPlans path (planStatusRe / planSystemsRe) so both subcommands
// agree on structure.
var (
	planSupersedesRe   = regexp.MustCompile(`(?m)^supersedes:\s*\[([^\]]*)\]\s*$`)
	planSupersededByRe = regexp.MustCompile(`(?m)^superseded_by:\s*\[([^\]]*)\]\s*$`)
	planExtendsRe      = regexp.MustCompile(`(?m)^extends:\s*\[([^\]]*)\]\s*$`)
	planExtendedByRe   = regexp.MustCompile(`(?m)^extended_by:\s*\[([^\]]*)\]\s*$`)
	// planTitleRe captures the raw value (quoted or bare); strip surrounding
	// quotes before slugifying. The non-greedy `.+?` plus the `\s*$` anchor
	// trims trailing whitespace inside the capture without a second pass.
	planTitleRe = regexp.MustCompile(`(?m)^title:\s*(.+?)\s*$`)
	// planCreatedRe captures the raw value so a malformed date can still be
	// reported by the value (vs. a regex miss reading as "field absent").
	// Format is then checked separately against planCreatedShapeRe.
	planCreatedRe      = regexp.MustCompile(`(?m)^created:\s*(\S.*?)\s*$`)
	planCreatedShapeRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`)
	// planKeyLineRe matches a top-level frontmatter key at the start of a
	// line — used by lintFrontmatterOrder to extract ordered keys without
	// pulling in a full YAML parser. Indented continuation lines and
	// comments are filtered before this regex runs.
	planKeyLineRe = regexp.MustCompile(`^([A-Za-z][A-Za-z0-9_-]*):`)
	earsSubjectRe = regexp.MustCompile(`\b[Tt]he ([A-Z][A-Za-z0-9]*(?:\s+[A-Z0-9][A-Za-z0-9]*)*)\s+shall\b`)
	taskLineRe    = regexp.MustCompile(`(?m)^\s*-\s*\[[ x]\]\s+(.*)$`)
	// (?ms): ^ matches line start, . matches newline. Block ends at next H2 or EOF.
	tasksBlockRe = regexp.MustCompile(`(?ms)^## Tasks\s*\n(.+?)(?:\n## |\z)`)
	// registryItemStartRe matches an indented YAML list-item marker inside
	// the `systems:` block — captures (leading whitespace, content after
	// `-`). The content is then re-run through registryKVLineRe so a one-line
	// `- id: foo` entry is parsed the same way as a multi-line entry whose
	// id/name live on indented continuation lines.
	registryItemStartRe = regexp.MustCompile(`^(\s+)-\s*(.*)$`)
	// registryKVLineRe captures `<key>: <value>` pairs anywhere — the
	// leading `\s*` swallows the per-entry indent. parseRegistry only cares
	// about the `id` and `name` keys; everything else (e.g. `brief`) is
	// matched and discarded by setRegistryField.
	registryKVLineRe = regexp.MustCompile(`^\s*([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$`)
)

// loadMaxPlanLines mirrors loadPrefixWidth for the max_plan_lines key in
// _config.lock. Falls back to defaultMaxPlanLines on any failure.
func loadMaxPlanLines(staxDir string) int {
	data, err := os.ReadFile(filepath.Join(staxDir, staxLockFile)) // #nosec G304 -- staxDir is project-local.
	if err != nil {
		return defaultMaxPlanLines
	}
	var cfg struct {
		MaxPlanLines int `json:"max_plan_lines"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil || cfg.MaxPlanLines <= 0 {
		return defaultMaxPlanLines
	}
	return cfg.MaxPlanLines
}

// runPlansLint validates every *.md file in staxDir against the plan schema.
// Takes no arguments — always operates on the standard .stax/ scaffold.
// Output contract:
//
//   - Per-file findings → stdout, one per line, prefixed with file path.
//   - A passing file emits `<path>: ok`.
//   - Summary `<ok> ok, <fail> failed` → stderr.
//   - Missing staxDir → 0 plans, exit 0.
//   - Exit 0 if every file passed, exit 1 if any failed.
func runPlansLint(args []string) {
	os.Exit(planLint(args, staxDir, os.Stdout, os.Stderr))
}

// planLint is the testable body of runPlansLint. Exit-code contract:
// 0 every file passed (or zero files), 1 at least one failed, 2 usage
// error or not-an-stax-project. Pulled out so unit tests can drive the
// per-file loop + summary line + exit-on-fail counter without
// shelling out a subprocess.
func planLint(args []string, staxDir string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("plans lint", flag.ContinueOnError)
	fs.SetOutput(stderr)
	cwdFlag := fs.String("cwd", "", "change to this directory before running (like git -C)")
	fs.Usage = func() {
		_, _ = fmt.Fprintln(stderr, "Usage: stax plans lint [--cwd PATH]")
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		_, _ = fmt.Fprintf(stderr, "stax plans lint takes no arguments (got %q)\n", fs.Arg(0))
		return 2
	}
	if err := applyCwd(*cwdFlag); err != nil {
		_, _ = fmt.Fprintln(stderr, "error:", err)
		return 2
	}
	if err := checkProject(); err != nil {
		_, _ = fmt.Fprintln(stderr, notProjectBanner)
		return 2
	}

	width := loadPrefixWidth(staxDir)
	maxLines := loadMaxPlanLines(staxDir)
	registryPath := filepath.Join(staxDir, staxSystemsFile)
	reg := parseRegistry(registryPath)

	// Glob only errors on bad pattern; ours is fixed. Missing staxDir → empty.
	files, _ := filepath.Glob(filepath.Join(staxDir, "*"+planFileExt))
	sort.Strings(files)
	knownSlugs := make(map[string]bool, len(files))
	for _, f := range files {
		knownSlugs[strings.TrimSuffix(filepath.Base(f), planFileExt)] = true
	}
	relations := scanPlansRelations(files)

	okCount, failCount := 0, 0
	for _, path := range files {
		findings := lintPlanFile(path, width, maxLines, reg, knownSlugs, relations, registryPath)
		if len(findings) > 0 {
			failCount++
			for _, f := range findings {
				_, _ = fmt.Fprintf(stdout, "%s: %s\n", path, f)
			}
		} else {
			okCount++
			_, _ = fmt.Fprintf(stdout, "%s: ok\n", path)
		}
	}
	_, _ = fmt.Fprintf(stderr, "\n%d ok, %d failed\n", okCount, failCount)
	// Anonymous-usage ping. Fires on the successful linter dispatch path
	// (parsing + project check passed); the early-return error paths
	// above intentionally skip it. Both failCount > 0 and failCount == 0
	// are reported so the backend can see the fail-rate distribution.
	track("plans_lint", telemetryEvent{
		"plan_count": strconv.Itoa(len(files)),
		"ok_count":   strconv.Itoa(okCount),
		"fail_count": strconv.Itoa(failCount),
	})
	flushTelemetry()
	if failCount > 0 {
		return 1
	}
	return 0
}

// registry pairs the two lookup directions parseRegistry produces:
//
//	byID   — "is this id from a plan's frontmatter `systems:` array
//	         actually declared in _data_systems.yaml?" (lint frontmatter
//	         membership). Maps id → display name.
//	byName — "what id does this EARS subject (a display name like
//	         `Auth Service` from criterion text) resolve to?" Used by
//	         lintEarsTasks to translate before set-comparing against the
//	         declared id array. Maps display name → id.
//
// Both maps are always non-nil so callers can index without a guard.
type registry struct {
	byID   map[string]string
	byName map[string]string
}

// parseRegistry walks the systems registry YAML and returns id↔name maps
// for every entry that carries BOTH an `id:` and a `name:` field.
// Hand-rolled to avoid pulling in a full YAML dependency for one file we
// control end-to-end; tracks current list-entry boundaries so a multi-line
// `- id: foo\n    name: Foo` form and the single-line `- id: foo` form
// produce the same in-memory result.
//
// Missing/unreadable file → empty registry; caller decides how to flag it.
// Entries that carry only `id:` or only `name:` are dropped silently —
// the broken plan referencing such a slug will surface its own lint
// finding instead.
func parseRegistry(path string) registry {
	empty := registry{byID: make(map[string]string), byName: make(map[string]string)}
	f, err := os.Open(path) // #nosec G304 -- path = staxDir/staxSystemsFile, both constants.
	if err != nil {
		return empty
	}
	defer func() { _ = f.Close() }()

	p := registryParser{reg: registry{byID: make(map[string]string), byName: make(map[string]string)}}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		p.feed(scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return empty
	}
	p.flush()
	return p.reg
}

// registryParser carries the line-by-line state parseRegistry walks: the
// accumulating registry, the partial entry being assembled, and whether
// we're inside the top-level `systems:` block. Lifted out of parseRegistry
// so the per-line branches live in feed() and parseRegistry stays a thin
// scan loop.
type registryParser struct {
	reg                registry
	curID, curName     string
	inSystems, inEntry bool
}

func (p *registryParser) flush() {
	if p.inEntry && p.curID != "" && p.curName != "" {
		p.reg.byID[p.curID] = p.curName
		p.reg.byName[p.curName] = p.curID
	}
	p.curID, p.curName = "", ""
	p.inEntry = false
}

func (p *registryParser) feed(line string) {
	trimmedRight := strings.TrimRight(line, " \t\r")
	if trimmedRight == "systems:" {
		p.flush()
		p.inSystems = true
		return
	}
	if !p.inSystems {
		return
	}
	// Blank lines stay inside the entry (and the block).
	if trimmedRight == "" {
		return
	}
	// Any unindented non-blank line that isn't a list item ends the block.
	if !isIndented(line) && !strings.HasPrefix(line, "-") {
		p.flush()
		p.inSystems = false
		return
	}
	if m := registryItemStartRe.FindStringSubmatch(line); m != nil {
		p.flush()
		p.inEntry = true
		if rest := strings.TrimSpace(m[2]); rest != "" {
			if kv := registryKVLineRe.FindStringSubmatch(rest); kv != nil {
				setRegistryField(&p.curID, &p.curName, kv[1], kv[2])
			}
		}
		return
	}
	if kv := registryKVLineRe.FindStringSubmatch(line); kv != nil {
		setRegistryField(&p.curID, &p.curName, kv[1], kv[2])
	}
}

// setRegistryField writes the id/name fields parseRegistry tracks; every
// other key (`brief`, future ad-hoc fields) is dropped. Pulled out so the
// item-start and continuation-line paths share one normalization
// (whitespace trim + quote strip).
func setRegistryField(id, name *string, key, raw string) {
	v := strings.Trim(strings.TrimSpace(raw), `"'`)
	switch key {
	case "id":
		*id = v
	case "name":
		*name = v
	}
}

// isIndented reports whether the first byte is a space or tab. Sufficient
// for parseRegistry's YAML-block boundary check.
func isIndented(line string) bool {
	if line == "" {
		return false
	}
	c := line[0]
	return c == ' ' || c == '\t'
}

// lintPlanFile runs every per-file lint check and returns a list of
// finding strings (empty = pass). Each finding is human-readable and
// stateless — callers prepend the file path. registryPath is passed in
// (rather than recomputed) so the "system not in registry" message uses
// the same string the lint hook logged at startup. reg carries both
// directions of the registry lookup (id→name and name→id) so the
// frontmatter check and the EARS-subject resolution share one parse.
func lintPlanFile(path string, width, maxLines int, reg registry, knownSlugs map[string]bool, relations plansRelations, registryPath string) []string {
	findings := lintFilename(filepath.Base(path), width)

	data, err := os.ReadFile(path) // #nosec G304 -- path is a staxDir glob result.
	if err != nil {
		return append(findings, fmt.Sprintf("read error: %v", err))
	}
	text := string(data)

	findings = append(findings, lintLineCount(text, maxLines)...)

	fm, body, fmFindings, stop := splitFrontmatter(text)
	findings = append(findings, fmFindings...)
	if stop {
		return findings
	}

	slug := strings.TrimSuffix(filepath.Base(path), planFileExt)
	title, titleFindings := lintTitle(fm)
	findings = append(findings, titleFindings...)
	findings = append(findings, lintStatus(fm)...)
	declaredSystems, sysFindings := lintSystems(fm, reg, registryPath)
	findings = append(findings, sysFindings...)
	findings = append(findings, lintRelationArray(slug, fm, "supersedes", planSupersedesRe, knownSlugs)...)
	findings = append(findings, lintRelationArray(slug, fm, "superseded_by", planSupersededByRe, knownSlugs)...)
	findings = append(findings, lintRelationArray(slug, fm, "extends", planExtendsRe, knownSlugs)...)
	findings = append(findings, lintRelationArray(slug, fm, "extended_by", planExtendedByRe, knownSlugs)...)
	findings = append(findings, lintBidirectional(slug, relations.extends, relations.extendedBy, "extends", "extended_by")...)
	findings = append(findings, lintBidirectional(slug, relations.supersedes, relations.supersededBy, "supersedes", "superseded_by")...)
	findings = append(findings, lintCreated(fm)...)
	findings = append(findings, lintFrontmatterOrder(fm)...)
	findings = append(findings, lintFilenameMatchesTitle(filepath.Base(path), width, title)...)
	findings = append(findings, lintRequiredSections(body)...)
	findings = append(findings, lintEarsTasks(body, declaredSystems, reg, registryPath)...)

	return findings
}

// lintFilename returns at most one finding for a non-conforming plan-file
// name. Pulled out so lintPlanFile's main flow reads as a sequence of
// per-section checks.
func lintFilename(name string, width int) []string {
	re := regexp.MustCompile(fmt.Sprintf(`^\d{%d}-[a-z0-9][a-z0-9-]*%s$`, width, regexp.QuoteMeta(planFileExt)))
	if re.MatchString(name) {
		return nil
	}
	return []string{fmt.Sprintf("filename %q does not match <prefix>-<slug>%s (prefix width %d, kebab-case slug)", name, planFileExt, width)}
}

// lintLineCount enforces the project line cap on a plan file. The +1
// adjustment captures the last line of a file without a trailing newline
// so two files with the same visible content produce the same count.
func lintLineCount(text string, maxLines int) []string {
	n := strings.Count(text, "\n")
	if !strings.HasSuffix(text, "\n") {
		n++
	}
	if n <= maxLines {
		return nil
	}
	return []string{fmt.Sprintf("file is %d lines; max is %d", n, maxLines)}
}

// splitFrontmatter peels the leading `---...---` block off `text`,
// returning (frontmatter, body, findings, stop). `stop=true` signals a
// fatal structural problem (no FM, unterminated FM) — callers should
// emit the returned findings and bail rather than continue with empty
// fm/body strings.
func splitFrontmatter(text string) (fm, body string, findings []string, stop bool) {
	if !strings.HasPrefix(text, "---") {
		return "", "", []string{"missing YAML frontmatter (must start with `---`)"}, true
	}
	end := strings.Index(text[3:], "\n---")
	if end < 0 {
		return "", "", []string{"frontmatter is unterminated (no closing `---`)"}, true
	}
	return text[3 : 3+end], text[3+end+4:], nil, false
}

// lintStatus validates the `status:` frontmatter field against the
// allowlist. Missing field and non-allowed value are reported as two
// distinct findings — the user sees exactly which problem to fix.
func lintStatus(fm string) []string {
	m := planStatusRe.FindStringSubmatch(fm)
	if m == nil {
		return []string{"missing required `status:` field"}
	}
	if !allowedStatuses[m[1]] {
		return []string{fmt.Sprintf("status %q is not one of %v", m[1], allowedStatusesSorted)}
	}
	return nil
}

// lintSystems validates the `systems:` frontmatter field. Each entry is
// an id (the kebab key from `_data_systems.yaml`); membership is checked
// against reg.byID. Returns the declared id list for the downstream
// EARS-equality check alongside any findings. Block-form `systems:` is
// rejected by the regex; only inline-array form is recognized.
func lintSystems(fm string, reg registry, registryPath string) (declared, findings []string) {
	m := planSystemsRe.FindStringSubmatch(fm)
	if m == nil {
		return nil, []string{"missing required `systems:` field (must be inline array)"}
	}
	declared = parseInlineSystems(m[1])
	if len(declared) == 0 {
		findings = append(findings, "`systems:` array is empty; at least one system is required")
	}
	for _, id := range declared {
		if _, ok := reg.byID[id]; !ok {
			findings = append(findings, fmt.Sprintf("declared system %q is not in %s", id, registryPath))
		}
	}
	return declared, findings
}

// lintRelationArray is the shared structure for `supersedes:`, `extends:`,
// `extended_by:`, `superseded_by:`: each entry must resolve to a sibling
// plan, and self-references are rejected. Field name is passed in so the
// finding strings are field-specific.
func lintRelationArray(selfSlug, fm, field string, re *regexp.Regexp, knownSlugs map[string]bool) []string {
	m := re.FindStringSubmatch(fm)
	if m == nil {
		return nil
	}
	var findings []string
	for _, slug := range parseInlineSystems(m[1]) {
		if slug == selfSlug {
			findings = append(findings, fmt.Sprintf("%s cannot reference the plan itself", field))
			continue
		}
		if !knownSlugs[slug] {
			findings = append(findings, fmt.Sprintf("%s %q does not match any plan file in the same directory", field, slug))
		}
	}
	return findings
}

// lintBidirectional enforces that a forward-link / back-link pair is
// symmetric across every plan. For each slug X in `fwd[self]`, X's
// `back` set must contain self; and for each slug Y in `back[self]`,
// Y's `fwd` set must contain self. Reports both directions so the user
// sees exactly which side is missing the link. fwdField / backField are
// the YAML key names (e.g. `extends`, `extended_by:`) used in the
// finding strings.
func lintBidirectional(self string, fwd, back map[string]map[string]bool, fwdField, backField string) []string {
	var findings []string
	for x := range fwd[self] {
		if !back[x][self] {
			findings = append(findings, fmt.Sprintf("%s %q but %q does not list this plan in its `%s:` array", fwdField, x, x, backField))
		}
	}
	for y := range back[self] {
		if !fwd[y][self] {
			findings = append(findings, fmt.Sprintf("%s %q but %q does not list this plan in its `%s:` array", backField, y, y, fwdField))
		}
	}
	sort.Strings(findings)
	return findings
}

// plansRelations bundles the four cross-plan adjacency maps the linter
// consults for forward/back-link integrity. Each entry is `slug → set of
// slugs in that plan's <field>:` array. Zero values are usable — nil-map
// lookups return false, which is the correct "no link" answer.
type plansRelations struct {
	extends      map[string]map[string]bool
	extendedBy   map[string]map[string]bool
	supersedes   map[string]map[string]bool
	supersededBy map[string]map[string]bool
}

// scanPlansRelations walks every plan file once and populates the four
// adjacency maps in plansRelations. Files that can't be read or have
// malformed frontmatter contribute nothing — lintPlanFile surfaces those
// as per-file findings on its own pass.
func scanPlansRelations(files []string) plansRelations {
	r := plansRelations{
		extends:      make(map[string]map[string]bool, len(files)),
		extendedBy:   make(map[string]map[string]bool, len(files)),
		supersedes:   make(map[string]map[string]bool, len(files)),
		supersededBy: make(map[string]map[string]bool, len(files)),
	}
	for _, path := range files {
		data, err := os.ReadFile(path) // #nosec G304 -- path is a staxDir glob result.
		if err != nil {
			continue
		}
		slug := strings.TrimSuffix(filepath.Base(path), planFileExt)
		fm, _, _, stop := splitFrontmatter(string(data))
		if stop {
			continue
		}
		if m := planExtendsRe.FindStringSubmatch(fm); m != nil {
			r.extends[slug] = inlineSlugSet(m[1])
		}
		if m := planExtendedByRe.FindStringSubmatch(fm); m != nil {
			r.extendedBy[slug] = inlineSlugSet(m[1])
		}
		if m := planSupersedesRe.FindStringSubmatch(fm); m != nil {
			r.supersedes[slug] = inlineSlugSet(m[1])
		}
		if m := planSupersededByRe.FindStringSubmatch(fm); m != nil {
			r.supersededBy[slug] = inlineSlugSet(m[1])
		}
	}
	return r
}

// inlineSlugSet renders an inline-array body (the captured group of
// e.g. planExtendsRe) into a set for O(1) bidirectional lookups.
func inlineSlugSet(raw string) map[string]bool {
	tokens := parseInlineSystems(raw)
	if len(tokens) == 0 {
		return nil
	}
	set := make(map[string]bool, len(tokens))
	for _, t := range tokens {
		set[t] = true
	}
	return set
}

// lintTitle validates the `title:` frontmatter field. Returns the parsed
// title (with surrounding quotes stripped) alongside any findings. Empty
// titles and missing fields are two distinct findings so the user sees
// exactly which problem to fix.
func lintTitle(fm string) (title string, findings []string) {
	m := planTitleRe.FindStringSubmatch(fm)
	if m == nil {
		return "", []string{"missing required `title:` field"}
	}
	title = strings.Trim(strings.TrimSpace(m[1]), `"'`)
	if title == "" {
		return "", []string{"`title:` value is empty"}
	}
	return title, nil
}

// lintCreated validates the `created:` frontmatter field against the
// ISO 8601 UTC form `YYYY-MM-DDTHH:MM:SSZ`. Calendar validity (e.g. Feb
// 30, hour 25) is out of scope — callers can layer a stricter check on
// top if needed.
func lintCreated(fm string) []string {
	m := planCreatedRe.FindStringSubmatch(fm)
	if m == nil {
		return []string{"missing required `created:` field (ISO 8601 UTC timestamp, e.g. 2026-05-23T14:30:00Z)"}
	}
	if !planCreatedShapeRe.MatchString(m[1]) {
		return []string{fmt.Sprintf("`created:` value %q is not an ISO 8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)", m[1])}
	}
	return nil
}

// lintFrontmatterOrder enforces "title first, created last" on the
// top-level frontmatter keys. Comment lines and blank lines are skipped;
// indented continuation lines (none today, since arrays are inline) would
// also be skipped because planKeyLineRe anchors at column 0.
func lintFrontmatterOrder(fm string) []string {
	var keys []string
	for _, raw := range strings.Split(fm, "\n") {
		line := strings.TrimRight(raw, "\r")
		if line == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if !isIndented(line) {
			if m := planKeyLineRe.FindStringSubmatch(line); m != nil {
				keys = append(keys, m[1])
			}
		}
	}
	if len(keys) == 0 {
		return nil
	}
	var findings []string
	if keys[0] != "title" {
		findings = append(findings, fmt.Sprintf("`title:` must be the first frontmatter field (got %q)", keys[0]))
	}
	if last := keys[len(keys)-1]; last != "created" {
		findings = append(findings, fmt.Sprintf("`created:` must be the last frontmatter field (got %q)", last))
	}
	return findings
}

// lintFilenameMatchesTitle verifies that the post-prefix portion of the
// filename equals slugify(title). Skipped when the title is empty
// (lintTitle already reported that) or when the filename doesn't carry a
// `<prefix>-<slug>.md` form (lintFilename already reported that) — the
// goal here is to surface the title↔filename drift, not to repeat
// upstream findings.
func lintFilenameMatchesTitle(name string, width int, title string) []string {
	if title == "" {
		return nil
	}
	re := regexp.MustCompile(fmt.Sprintf(`^\d{%d}-(.+)%s$`, width, regexp.QuoteMeta(planFileExt)))
	m := re.FindStringSubmatch(name)
	if m == nil {
		return nil
	}
	want := slugify(title)
	if want == "" {
		return []string{fmt.Sprintf("title %q has no slug-able characters; cannot match filename slug %q", title, m[1])}
	}
	if m[1] != want {
		return []string{fmt.Sprintf("filename slug %q does not match slugify(title) %q", m[1], want)}
	}
	return nil
}

// lintRequiredSections is a presence-only check: each header in
// requiredSections must appear somewhere in the body. Order and content
// are out of scope here; deeper structural checks belong in their own
// helper if/when added.
func lintRequiredSections(body string) []string {
	var findings []string
	for _, header := range requiredSections {
		if !strings.Contains(body, header) {
			findings = append(findings, fmt.Sprintf("missing required section %q", header))
		}
	}
	return findings
}

// lintEarsTasks extracts EARS-criterion subjects from the `## Tasks`
// block and checks two invariants:
//
//  1. Every subject (a display name like "Auth Service") resolves to a
//     registry entry via reg.byName.
//  2. The set of resolved subject ids equals the declared `systems:`
//     id set exactly. The equality rule keeps frontmatter honest —
//     declared systems can't drift from what the tasks actually exercise.
//
// declared carries the kebab ids parsed from the plan's frontmatter; EARS
// subjects are translated to ids before the set comparison so both sides
// share the same coordinate system.
func lintEarsTasks(body string, declared []string, reg registry, registryPath string) []string {
	var tasksBlock string
	if m := tasksBlockRe.FindStringSubmatch(body); m != nil {
		tasksBlock = m[1]
	}
	subjectIDs := make(map[string]bool)
	unknownNames := make(map[string]bool)
	for _, lineMatch := range taskLineRe.FindAllStringSubmatch(tasksBlock, -1) {
		for _, subjMatch := range earsSubjectRe.FindAllStringSubmatch(lineMatch[1], -1) {
			name := subjMatch[1]
			if id, ok := reg.byName[name]; ok {
				subjectIDs[id] = true
			} else {
				unknownNames[name] = true
			}
		}
	}

	// Stable iteration order so findings are deterministic in tests.
	sortedUnknown := make([]string, 0, len(unknownNames))
	for n := range unknownNames {
		sortedUnknown = append(sortedUnknown, n)
	}
	sort.Strings(sortedUnknown)

	var findings []string
	for _, n := range sortedUnknown {
		findings = append(findings, fmt.Sprintf("EARS subject %q is not in %s", n, registryPath))
	}

	declaredSet := make(map[string]bool, len(declared))
	for _, s := range declared {
		declaredSet[s] = true
	}
	if extra := setDifference(subjectIDs, declaredSet); len(extra) > 0 {
		findings = append(findings, fmt.Sprintf("EARS tasks name systems not in `systems:`: %v", extra))
	}
	if missing := setDifference(declaredSet, subjectIDs); len(missing) > 0 {
		findings = append(findings, fmt.Sprintf("`systems:` declares systems not used in any EARS task: %v", missing))
	}
	return findings
}

// setDifference returns sorted `a - b` (elements in a that aren't in b).
// Non-nil empty slice on no-diff for ease of length checks at the call site.
func setDifference(a, b map[string]bool) []string {
	out := make([]string, 0)
	for s := range a {
		if !b[s] {
			out = append(out, s)
		}
	}
	sort.Strings(out)
	return out
}

// ---------- plans slugify ----------

// slugifySepRe matches one-or-more runs of non-slug bytes after lowercasing.
// Anything outside [a-z0-9] collapses into a single `-`; leading/trailing
// dashes are then trimmed so the result satisfies the filename regex
// `^[a-z0-9][a-z0-9-]*$` enforced by lintFilename.
var slugifySepRe = regexp.MustCompile(`[^a-z0-9]+`)

// slugify converts a plan title into the kebab-case slug used as the
// post-prefix portion of the filename. Returns an empty string when the
// input has no [a-z0-9] characters to anchor the slug — callers treat that
// as an error.
func slugify(title string) string {
	return strings.Trim(slugifySepRe.ReplaceAllString(strings.ToLower(title), "-"), "-")
}

// extractCwdFromHead consumes leading `--cwd <PATH>` / `--cwd=<PATH>`
// pairs from args and returns the last value plus the remaining args.
// Used by planSlugify because flag.Parse is unavailable to slugify
// (its title positional may start with `-`). On a malformed `--cwd`
// (no value after the bare form) it writes a usage error to stderr
// and returns ok=false so the caller can exit 2 immediately. Multiple
// occurrences keep the last value, mirroring flag.String's last-wins
// semantics for the other plan subcommands.
func extractCwdFromHead(args []string, stderr io.Writer) (cwd string, rest []string, ok bool) {
	rest = args
	for len(rest) > 0 {
		switch {
		case rest[0] == "--cwd":
			if len(rest) < 2 {
				_, _ = fmt.Fprintln(stderr, "stax plans slugify: --cwd requires a value")
				return "", nil, false
			}
			cwd = rest[1]
			rest = rest[2:]
		case strings.HasPrefix(rest[0], "--cwd="):
			cwd = strings.TrimPrefix(rest[0], "--cwd=")
			rest = rest[1:]
		default:
			return cwd, rest, true
		}
	}
	return cwd, rest, true
}

// runPlansSlugify takes a single positional argument (the title) and prints
// its kebab-case slug to stdout. Exits 2 on missing/extra arguments or when
// the title contains no characters that survive slugification. No project
// check — slugify is a pure transform and is useful before `stax init`.
// runPlansSlugify is the only subcommand that takes a single positional.
// flag.Parse can't help here — the title may legitimately start with `-`
// (e.g. "---draft note"), and flag.Parse would reject it as an unknown
// flag. Instead we hand-parse the leading flag-like tokens we care about:
// an optional `--cwd <PATH>` / `--cwd=<PATH>` pair (chdir before any
// further work — kept for uniform flag parsing across every stax
// subcommand even though slugify itself is cwd-independent), `-h`/`--help`
// print usage, `--` is a legacy separator stripped if present, and
// everything else is treated as the title.
func runPlansSlugify(args []string) {
	os.Exit(planSlugify(args, os.Stdout, os.Stderr))
}

// planSlugify is the testable body of runPlansSlugify. Exit-code
// contract: 0 happy (or -h/--help), 2 usage error (missing/extra args,
// bad --cwd, or unsluggable title). No staxDir argument because slugify
// is a pure transform — useful before `stax init`, so it deliberately
// skips the project marker check.
func planSlugify(args []string, stdout, stderr io.Writer) int {
	cwdPath, rest, ok := extractCwdFromHead(args, stderr)
	if !ok {
		return 2
	}
	args = rest
	if len(args) >= 1 {
		switch args[0] {
		case "-h", "--help":
			_, _ = fmt.Fprintln(stderr, `Usage: stax plans slugify [--cwd PATH] "<title>"`)
			return 0
		case "--":
			args = args[1:]
		}
	}
	if err := applyCwd(cwdPath); err != nil {
		_, _ = fmt.Fprintln(stderr, "error:", err)
		return 2
	}
	if len(args) != 1 {
		_, _ = fmt.Fprintln(stderr, `Usage: stax plans slugify [--cwd PATH] "<title>"`)
		_, _ = fmt.Fprintln(stderr, `stax plans slugify takes exactly one positional argument: the title (quote it)`)
		return 2
	}
	title := args[0]
	slug := slugify(title)
	if slug == "" {
		_, _ = fmt.Fprintf(stderr, "stax plans slugify: title %q has no slug-able characters\n", title)
		return 2
	}
	_, _ = fmt.Fprintln(stdout, slug)
	return 0
}
