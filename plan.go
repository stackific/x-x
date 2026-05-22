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

// runPlan dispatches `x-x plan <subcommand>`. Future plan-tooling commands
// (e.g. `lint`) can be added here without restructuring, the same way
// `runSkill` is shaped.
func runPlan(args []string) {
	if len(args) == 0 {
		printPlanUsage(os.Stderr)
		os.Exit(2)
	}
	switch args[0] {
	case "next-prefix":
		runPlanNextPrefix(args[1:])
	case "list":
		runPlanList(args[1:])
	case "lint":
		runPlanLint(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown plan subcommand: %s\n", args[0])
		printPlanUsage(os.Stderr)
		os.Exit(2)
	}
}

// printPlanUsage writes the `x-x plan` help block to w. Mirrors the
// printSkillUsage shape (one-line subcommand summaries) so the two help
// surfaces stay visually aligned; both ride on a writer parameter rather
// than os.Stderr directly so future `--help` paths can redirect to stdout.
func printPlanUsage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage: x-x plan <subcommand>")
	_, _ = fmt.Fprintln(w, "  next-prefix   Print the next unused zero-padded plan prefix")
	_, _ = fmt.Fprintln(w, "  list          List plans with slug, status, and declared systems")
	_, _ = fmt.Fprintln(w, "  lint          Validate every plan file against the project schema")
}

// runPlanNextPrefix prints the next available zero-padded plan prefix in
// planDir (the canonical ".x-plan" under cwd). Takes no arguments — the
// directory is not user-configurable; planDir is the single source of truth.
//
// Prefix width is read from <planDir>/<planConfigLockFile> (JSON), falling
// back to defaultPrefixWidth when the lock file is missing or malformed.
// Missing planDir is treated as empty (next prefix = 1), so the command is
// safe to run before `x-x init` has seeded the scaffold.
func runPlanNextPrefix(args []string) {
	fs := flag.NewFlagSet("plan next-prefix", flag.ExitOnError)
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: x-x plan next-prefix")
	}
	_ = fs.Parse(args)
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "x-x plan next-prefix takes no arguments (got %q)\n", fs.Arg(0))
		os.Exit(2)
	}
	requireProject()

	width := loadPrefixWidth(planDir)
	highest := scanHighestPrefix(planDir, width)
	fmt.Printf("%0*d\n", width, highest+1)
}

// loadPrefixWidth reads prefix_width from <plansDir>/<planConfigLockFile>.
// Returns defaultPrefixWidth on any read/parse failure so the command is
// usable before `x-x init` has seeded the lock file.
func loadPrefixWidth(plansDir string) int {
	data, err := os.ReadFile(filepath.Join(plansDir, planConfigLockFile)) // #nosec G304 -- plansDir is a CLI arg, path is project-local.
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
// names in plansDir whose first `width` characters are digits. Matches the
// regex `^(\d{width})` — the prefix does NOT have to be followed by `-`
// here; that stricter shape is enforced by lint-plans, not by the
// next-prefix lookup.
func scanHighestPrefix(plansDir string, width int) int {
	entries, err := os.ReadDir(plansDir)
	if err != nil {
		return 0
	}
	re := regexp.MustCompile(fmt.Sprintf(`^(\d{%d})`, width))
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

// runPlanList prints one tab-separated row per plan in planDir whose
// filename matches `<prefix-digits>-<slug>.md`. Each row is
// `<slug>\t<status>\t<sys1>,<sys2>,...`, sorted by zero-padded prefix
// (which equals numerical order). Filter flags:
//
//	--status NAME[,NAME...]   repeatable; keeps only matching statuses
//	--system NAME             repeatable; OR semantics across declared systems
//
// Files matching the filename pattern but missing frontmatter, `status:`,
// or `systems:` produce stderr warnings and are skipped. Missing planDir
// is treated as empty (no rows, no error) so the command is safe to run
// before `x-x init` has seeded the scaffold.
func runPlanList(args []string) {
	fs := flag.NewFlagSet("plan list", flag.ExitOnError)
	var statusFlag, systemFlag stringSliceFlag
	fs.Var(&statusFlag, "status", "keep only plans whose status matches (repeatable, comma-separated)")
	fs.Var(&systemFlag, "system", "keep only plans whose systems contain this name (repeatable; OR semantics)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: x-x plan list [--status NAME[,NAME...]] [--system NAME]")
	}
	_ = fs.Parse(args)
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "x-x plan list takes no positional arguments (got %q)\n", fs.Arg(0))
		os.Exit(2)
	}
	requireProject()

	statusSet := toFilterSet(statusFlag)
	systemSet := toFilterSet(systemFlag)

	width := loadPrefixWidth(planDir)
	rows, err := listPlans(planDir, width, os.Stderr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "x-x plan list: %v\n", err)
		os.Exit(1)
	}

	for _, r := range rows {
		if len(statusSet) > 0 && !statusSet[r.status] {
			continue
		}
		if len(systemSet) > 0 && !anySystemMatches(r.systems, systemSet) {
			continue
		}
		fmt.Printf("%s\t%s\t%s\n", r.slug, r.status, strings.Join(r.systems, ","))
	}
}

// stringSliceFlag is a flag.Value that accumulates values across repeated
// occurrences AND splits comma-separated input. Matches the Python
// `action="append"` + comma-aware semantics list-plans used to expose.
type stringSliceFlag []string

// String renders the accumulated values as a comma list — flag's default
// help text uses this, so the format mirrors what users would pass on
// the command line.
func (s *stringSliceFlag) String() string { return strings.Join(*s, ",") }

// Set is invoked once per `--<flag> <value>` occurrence. It splits on
// commas, trims whitespace per token, and appends non-empty tokens to
// the underlying slice — matching the Python argparse "append + comma"
// idiom list-plans.py used to expose.
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
// needles. Used to implement OR semantics for the `--system` filter.
func anySystemMatches(haystack []string, needles map[string]bool) bool {
	for _, h := range haystack {
		if needles[h] {
			return true
		}
	}
	return false
}

// planRow is one parsed plan file ready for emission.
type planRow struct {
	slug    string
	status  string
	systems []string
}

// Frontmatter regexes — anchored multi-line. Match the Python script's
// shape exactly so behavior carries over: only inline-array `systems:` is
// recognized; block form (`- entry` on subsequent lines) is rejected.
var (
	planStatusRe  = regexp.MustCompile(`(?m)^status:\s*(\S+)\s*$`)
	planSystemsRe = regexp.MustCompile(`(?m)^systems:\s*\[([^\]]*)\]\s*$`)
)

// listPlans walks plansDir, parses every file whose name matches
// `<width digits>-<anything>.md`, and returns the parsed rows in
// prefix-ascending order. Warnings for filename-matching files with
// malformed/missing frontmatter go to warnW so the caller can route them
// (CLI sends them to stderr; tests can capture them).
//
// Missing plansDir is treated as "no plans" (returns nil, nil) so callers
// don't need to special-case the pre-init state.
func listPlans(plansDir string, width int, warnW io.Writer) ([]planRow, error) {
	entries, err := os.ReadDir(plansDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}

	// `<width digits>-<at least one char><planFileExt>`. The trailing
	// extension is part of the contract enforced by lint-plans; we match
	// the same shape so stray docs (README.md, _data_systems.yaml) are
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
		row, ok := parsePlan(filepath.Join(plansDir, name), warnW)
		if !ok {
			continue
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// parsePlan reads one plan file and extracts (slug, status, systems).
// Returns (_, false) and emits a stderr-style warning to warnW when the
// file lacks frontmatter or is missing a required field. This mirrors
// the warn-and-skip behavior of the Python list-plans.py.
func parsePlan(path string, warnW io.Writer) (planRow, bool) {
	data, err := os.ReadFile(path) // #nosec G304 -- path is constructed from a CLI-driven ReadDir of plansDir.
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

// ---------- plan lint ----------

// Allowed plan statuses. allowedStatusesSorted is the deterministic form
// rendered in finding messages (matches `sorted(ALLOWED_STATUSES)` from
// the prior Python script).
var (
	allowedStatuses       = map[string]bool{"valid": true, "superseded": true, "deprecated": true}
	allowedStatusesSorted = []string{"deprecated", "superseded", "valid"}
)

// Required body section headers. Presence-only check — section order is
// the author's responsibility (caught by review, not lint).
var requiredSections = []string{"## Goal", "## Approach", "## Tasks"}

// Lint-only regexes. Frontmatter status/systems regexes are reused from
// the listPlans path (planStatusRe / planSystemsRe) so both subcommands
// agree on shape.
var (
	planSupersedesRe = regexp.MustCompile(`(?m)^supersedes:\s*\[([^\]]*)\]\s*$`)
	earsSubjectRe    = regexp.MustCompile(`\b[Tt]he ([A-Z][A-Za-z0-9]*(?:\s+[A-Z0-9][A-Za-z0-9]*)*)\s+shall\b`)
	taskLineRe       = regexp.MustCompile(`(?m)^\s*-\s*\[[ x]\]\s+(.*)$`)
	// (?ms): ^ matches line start, . matches newline. Block ends at next H2 or EOF.
	tasksBlockRe       = regexp.MustCompile(`(?ms)^## Tasks\s*\n(.+?)(?:\n## |\z)`)
	registryNameLineRe = regexp.MustCompile(`^\s*name:\s*(.+?)\s*$`)
)

// loadMaxPlanLines mirrors loadPrefixWidth for the max_plan_lines key in
// _config.lock. Falls back to defaultMaxPlanLines on any failure.
func loadMaxPlanLines(plansDir string) int {
	data, err := os.ReadFile(filepath.Join(plansDir, planConfigLockFile)) // #nosec G304 -- plansDir is project-local.
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

// runPlanLint validates every *.md file in planDir against the plan schema.
// Takes no arguments — always operates on the canonical .x-plan/ scaffold.
// Output contract matches the prior lint-plans.py so existing hooks don't
// change shape:
//
//   - Per-file findings → stdout, one per line, prefixed with file path.
//   - A passing file emits `<path>: ok`.
//   - Summary `<ok> ok, <fail> failed` → stderr.
//   - Missing planDir → 0 plans, exit 0.
//   - Exit 0 if every file passed, exit 1 if any failed.
func runPlanLint(args []string) {
	fs := flag.NewFlagSet("plan lint", flag.ExitOnError)
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: x-x plan lint")
	}
	_ = fs.Parse(args)
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "x-x plan lint takes no arguments (got %q)\n", fs.Arg(0))
		os.Exit(2)
	}
	requireProject()

	width := loadPrefixWidth(planDir)
	maxLines := loadMaxPlanLines(planDir)
	registryPath := filepath.Join(planDir, planSystemsFile)
	registry := parseRegistryNames(registryPath)
	if len(registry) == 0 {
		fmt.Fprintf(os.Stderr, "warning: %s is missing or has no systems; system checks will fail\n", registryPath)
	}

	// Glob only errors on bad pattern; ours is fixed. Missing planDir → empty.
	files, _ := filepath.Glob(filepath.Join(planDir, "*"+planFileExt))
	sort.Strings(files)

	// Pre-compute slugs so per-file supersedes checks are O(1).
	knownSlugs := make(map[string]bool, len(files))
	for _, f := range files {
		knownSlugs[strings.TrimSuffix(filepath.Base(f), planFileExt)] = true
	}

	okCount, failCount := 0, 0
	for _, path := range files {
		findings := lintPlanFile(path, width, maxLines, registry, knownSlugs, registryPath)
		if len(findings) > 0 {
			failCount++
			for _, f := range findings {
				fmt.Printf("%s: %s\n", path, f)
			}
		} else {
			okCount++
			fmt.Printf("%s: ok\n", path)
		}
	}
	fmt.Fprintf(os.Stderr, "\n%d ok, %d failed\n", okCount, failCount)
	if failCount > 0 {
		os.Exit(1)
	}
}

// parseRegistryNames walks the systems registry YAML and returns the set
// of `name:` values inside the top-level `systems:` block. Hand-rolled
// parser tracking the specific shape of _data_systems.yaml so we don't
// pull in a full YAML dependency for one file we control end-to-end.
// Missing/unreadable file → empty set; caller decides how to flag it.
func parseRegistryNames(path string) map[string]bool {
	f, err := os.Open(path) // #nosec G304 -- path = planDir/planSystemsFile, both constants.
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()
	names := make(map[string]bool)
	inSystems := false
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimRight(line, " \t\r") == "systems:" {
			inSystems = true
			continue
		}
		if !inSystems {
			continue
		}
		// Block ends at any unindented non-blank line that isn't a list item.
		if line != "" && !isIndented(line) && !strings.HasPrefix(line, "-") {
			inSystems = false
			continue
		}
		if m := registryNameLineRe.FindStringSubmatch(line); m != nil {
			names[strings.Trim(strings.TrimSpace(m[1]), `"'`)] = true
		}
	}
	return names
}

// isIndented reports whether the first byte is a space or tab. Sufficient
// for parseRegistryNames' YAML-block boundary check.
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
// the same string the lint hook logged at startup.
func lintPlanFile(path string, width, maxLines int, registry, knownSlugs map[string]bool, registryPath string) []string {
	findings := lintFilename(filepath.Base(path), width)

	data, err := os.ReadFile(path) // #nosec G304 -- path is a planDir glob result.
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

	findings = append(findings, lintStatus(fm)...)
	declaredSystems, sysFindings := lintSystems(fm, registry, registryPath)
	findings = append(findings, sysFindings...)
	findings = append(findings, lintSupersedes(fm, knownSlugs)...)
	findings = append(findings, lintRequiredSections(body)...)
	findings = append(findings, lintEarsTasks(body, declaredSystems, registry, registryPath)...)

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

// lintSystems validates the `systems:` frontmatter field. Returns the
// parsed list of declared systems (for the downstream EARS-equality
// check) alongside any findings. Block-form `systems:` is rejected by
// the regex; only inline-array form is recognized.
func lintSystems(fm string, registry map[string]bool, registryPath string) (declared, findings []string) {
	m := planSystemsRe.FindStringSubmatch(fm)
	if m == nil {
		return nil, []string{"missing required `systems:` field (must be inline array)"}
	}
	declared = parseInlineSystems(m[1])
	if len(declared) == 0 {
		findings = append(findings, "`systems:` array is empty; at least one system is required")
	}
	for _, s := range declared {
		if !registry[s] {
			findings = append(findings, fmt.Sprintf("declared system %q is not in %s", s, registryPath))
		}
	}
	return declared, findings
}

// lintSupersedes verifies every slug in the optional `supersedes:` array
// resolves to a sibling plan filename. Returns nothing when the field is
// absent — supersedes is opt-in.
func lintSupersedes(fm string, knownSlugs map[string]bool) []string {
	m := planSupersedesRe.FindStringSubmatch(fm)
	if m == nil {
		return nil
	}
	var findings []string
	for _, slug := range parseInlineSystems(m[1]) {
		if !knownSlugs[slug] {
			findings = append(findings, fmt.Sprintf("supersedes %q does not match any plan file in the same directory", slug))
		}
	}
	return findings
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
// block and checks two invariants: every subject exists in the registry,
// and the subject set equals the declared `systems:` set exactly. The
// equality rule keeps frontmatter honest — declared systems can't drift
// from what the tasks actually exercise.
func lintEarsTasks(body string, declared []string, registry map[string]bool, registryPath string) []string {
	var tasksBlock string
	if m := tasksBlockRe.FindStringSubmatch(body); m != nil {
		tasksBlock = m[1]
	}
	subjects := make(map[string]bool)
	for _, lineMatch := range taskLineRe.FindAllStringSubmatch(tasksBlock, -1) {
		for _, subjMatch := range earsSubjectRe.FindAllStringSubmatch(lineMatch[1], -1) {
			subjects[subjMatch[1]] = true
		}
	}

	// Stable iteration order so findings are deterministic in tests.
	sortedSubjects := make([]string, 0, len(subjects))
	for s := range subjects {
		sortedSubjects = append(sortedSubjects, s)
	}
	sort.Strings(sortedSubjects)

	var findings []string
	for _, s := range sortedSubjects {
		if !registry[s] {
			findings = append(findings, fmt.Sprintf("EARS subject %q is not in %s", s, registryPath))
		}
	}

	declaredSet := make(map[string]bool, len(declared))
	for _, s := range declared {
		declaredSet[s] = true
	}
	if extra := setDifference(subjects, declaredSet); len(extra) > 0 {
		findings = append(findings, fmt.Sprintf("EARS tasks name systems not in `systems:`: %v", extra))
	}
	if missing := setDifference(declaredSet, subjects); len(missing) > 0 {
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
