// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// TestE2EShellConstantsMatchGo enforces the AGENTS.md hard rule that on-disk
// path components have a single source of truth. The shell harness in
// scripts/e2e_test.sh mirrors constants.go in a `readonly`-declarations
// block at the top; this test parses that block and fails loudly if any
// value drifts from the Go side.
//
// Add a constant to constants.go → mirror it in e2e_test.sh → add a row to
// the table below. Forgetting any one of those triggers the failure.
func TestE2EShellConstantsMatchGo(t *testing.T) {
	const shellPath = "scripts/e2e_test.sh"
	decls, err := parseShellReadonly(shellPath)
	if err != nil {
		t.Fatalf("parse %s: %v", shellPath, err)
	}

	// Mapping: shell variable name → expected Go-side value.
	want := map[string]string{
		"XX_HOME_DIR":                   xxHomeDir,
		"XX_CONFIG_FILE":                xxConfigFile,
		"AGENTS_EMBED_ROOT":             agentsEmbedRoot,
		"SKILLS_SUBDIR":                 skillsSubdir,
		"PLANS_DIR":                     plansDir,
		"PLANS_CONFIG_LOCK":             plansConfigLockFile,
		"PLANS_SYSTEMS_FILE":            plansSystemsFile,
		"DEFAULT_PREFIX_WIDTH":          strconv.Itoa(defaultPrefixWidth),
		"PLANS_LIST_OVERFLOW_THRESHOLD": strconv.Itoa(plansListOverflowThreshold),

		"SKILL_X_PLAN_DIR":    skillXPlanDir,
		"SKILL_X_X_DIR":       skillXXDir,
		"SKILL_MANIFEST_FILE": skillManifestFile,

		"CLAUDE_SKILLS_REL":   agentTargets[0].skillsRel,
		"CLAUDE_CONFIG_REL":   agentTargets[0].configRel,
		"CODEX_SKILLS_REL":    agentTargets[1].skillsRel,
		"CODEX_CONFIG_REL":    agentTargets[1].configRel,
		"OPENCODE_SKILLS_REL": agentTargets[2].skillsRel,
		// OpenCode has no per-agent config bundled — agentTargets[2].configRel
		// is "" and is intentionally not mirrored on the shell side.
		"COPILOT_SKILLS_REL": agentTargets[3].skillsRel,
		// Copilot has no per-agent config bundled — agentTargets[3].configRel
		// is "" and is intentionally not mirrored on the shell side.
		"KILO_SKILLS_REL": agentTargets[4].skillsRel,
		// Kilo Code has no per-agent config bundled — agentTargets[4].configRel
		// is "" and is intentionally not mirrored on the shell side.
	}

	for name, expected := range want {
		got, ok := decls[name]
		if !ok {
			t.Errorf("%s: shell file is missing `readonly %s=...` (declare it to mirror the Go constant)", shellPath, name)
			continue
		}
		if got != expected {
			t.Errorf("%s: %s = %q, want %q (drifted from Go constant)", shellPath, name, got, expected)
		}
	}

	// OWNED_SKILLS is a space-separated flattening of ownedSkills (in order).
	wantOwned := strings.Join(ownedSkills, " ")
	if got := decls["OWNED_SKILLS"]; got != wantOwned {
		t.Errorf("%s: OWNED_SKILLS = %q, want %q (must mirror ownedSkills in order)",
			shellPath, got, wantOwned)
	}

	// EMBED_README is the entry in skipFromEmbed. Validate set-equality —
	// drift here means either the embed-skip set grew/shrunk in Go without
	// the shell mirror following, or vice-versa.
	wantSkip := map[string]bool{decls["EMBED_README"]: true}
	if !mapsEqual(wantSkip, skipFromEmbed) {
		t.Errorf("%s: EMBED_README=%q does not match skipFromEmbed=%v",
			shellPath, decls["EMBED_README"], skipFromEmbed)
	}
}

// parseShellReadonly reads a shell script and extracts `readonly NAME="value"`
// (or `readonly NAME=value` / `readonly NAME=N`) declarations into a map.
// Inline comments after the value are stripped. Quoted values have their
// surrounding double-quotes removed. `${VAR}` references inside the value
// are resolved against earlier entries — so composed values like
// `${PLANS_DIR}/${PLANS_CONFIG_LOCK}` resolve to their final form, and
// space-joined collections like OWNED_SKILLS are validated end-to-end.
func parseShellReadonly(path string) (map[string]string, error) {
	f, err := os.Open(path) // #nosec G304 -- test-controlled path.
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()

	assignRe := regexp.MustCompile(`^\s*readonly\s+([A-Z_][A-Z0-9_]*)=(.+?)\s*(?:#.*)?$`)
	refRe := regexp.MustCompile(`\$\{([A-Z_][A-Z0-9_]*)\}`)
	out := map[string]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		m := assignRe.FindStringSubmatch(scanner.Text())
		if m == nil {
			continue
		}
		name, raw := m[1], strings.TrimSpace(m[2])
		// Strip surrounding double-quotes if present.
		if len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"' {
			raw = raw[1 : len(raw)-1]
		}
		// Resolve ${VAR} references against earlier declarations. The
		// scanner processes the file top-down and `readonly` blocks at
		// the top of the script are ordered to declare bases before
		// compositions, so single-pass resolution is sufficient.
		raw = refRe.ReplaceAllStringFunc(raw, func(token string) string {
			ref := token[2 : len(token)-1]
			if v, ok := out[ref]; ok {
				return v
			}
			return token // leave dangling refs visible for debugging
		})
		out[name] = raw
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan %s: %w", path, err)
	}
	return out, nil
}

// mapsEqual reports whether two `map[string]bool` values have identical
// key/value pairs. Used as the comparator for the embed-skip set check
// in TestE2EShellConstantsMatchGo; pulled into a helper because
// reflect.DeepEqual returns true for two empty maps of different declared
// nilness, which would mask drift in one direction.
func mapsEqual(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}
