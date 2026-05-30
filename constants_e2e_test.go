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
		"STAX_DIR":                           staxDir,
		"STAX_CONFIG_FILE":                   staxConfigFile,
		"AGENTS_EMBED_ROOT":                  agentsEmbedRoot,
		"SKILLS_SUBDIR":                      skillsSubdir,
		"STAX_LOCK_FILE":                     staxLockFile,
		"STAX_SYSTEMS_FILE":                  staxSystemsFile,
		"DEFAULT_PREFIX_WIDTH":               strconv.Itoa(defaultPrefixWidth),
		"WORK_ITEMS_LIST_OVERFLOW_THRESHOLD": strconv.Itoa(workItemsListOverflowThreshold),

		"SKILL_SCOPE_DIR":     skillScopeDir,
		"SKILL_SHIP_DIR":      skillShipDir,
		"SKILL_MANIFEST_FILE": skillManifestFile,

		"CLAUDE_SKILLS_REL": agentByKey("claude").skillsRel,
		"CLAUDE_CONFIG_REL": agentByKey("claude").configRel,
		"CLINE_SKILLS_REL":  agentByKey("cline").skillsRel,
		// Cline bundles no per-agent config (configRel is ""); no mirror needed.
		"CODEX_SKILLS_REL":    agentByKey("codex").skillsRel,
		"CODEX_CONFIG_REL":    agentByKey("codex").configRel,
		"CONTINUE_SKILLS_REL": agentByKey("continue").skillsRel,
		"CURSOR_SKILLS_REL":   agentByKey("cursor").skillsRel,
		// Cursor has a single user-scope override; userSkillsRels[0] resolves
		// it under the slice-typed field shared with multi-destination agents
		// (Google Antigravity below).
		"CURSOR_USER_SKILLS_REL":  agentByKey("cursor").userSkillsRels[0],
		"COPILOT_SKILLS_REL":      agentByKey("copilot").skillsRel,
		"COPILOT_CONFIG_REL":      agentByKey("copilot").configRel,
		"COPILOT_USER_CONFIG_REL": agentByKey("copilot").userConfigRel,
		// Google Antigravity is the only registry row that installs skills
		// into multiple user-scope discovery roots (`agy` CLI-local skills
		// AND the Antigravity tool family's shared skills root). Each entry
		// in userSkillsRels gets its own mirror so the shell harness can
		// assert presence at both destinations and the bash sandbox can
		// wipe the parent of each between cases. Hook config is symmetric
		// across scopes (configRel == userConfigRel == ".gemini"), so no
		// USER_CONFIG_REL mirror is needed.
		"ANTIGRAVITY_SKILLS_REL":             agentByKey("antigravity").skillsRel,
		"ANTIGRAVITY_USER_SKILLS_REL_CLI":    agentByKey("antigravity").userSkillsRels[0],
		"ANTIGRAVITY_USER_SKILLS_REL_SHARED": agentByKey("antigravity").userSkillsRels[1],
		"ANTIGRAVITY_CONFIG_REL":             agentByKey("antigravity").configRel,
		"KILO_SKILLS_REL":                    agentByKey("kilo").skillsRel,
		"OPENCODE_SKILLS_REL":                agentByKey("opencode").skillsRel,
		"OPENCODE_CONFIG_REL":                agentByKey("opencode").configRel,
		"OPENCODE_USER_CONFIG_REL":           agentByKey("opencode").userConfigRel,
		"PI_SKILLS_REL":                      agentByKey("pi").skillsRel,
		"PI_CONFIG_REL":                      agentByKey("pi").configRel,
		"PI_USER_CONFIG_REL":                 agentByKey("pi").userConfigRel,
		"ZED_SKILLS_REL":                     agentByKey("zed").skillsRel,
		// Continue / Cursor / Kilo / Zed each bundle no per-agent
		// config (configRel is ""), so no *_CONFIG_REL mirror is needed.

		// Local-server constants — the bare-stax HTTP listener (server.go)
		// and the /api/* path constants. The shell harness spawns the
		// server and curls these paths, so any drift would make the e2e
		// probe a different URL than the Go server registers.
		"STAX_SERVER_LISTEN_ADDR": serverListenAddr,
		"STAX_SERVER_DISPLAY_URL": serverDisplayURL,
		"STAX_API_STATS_PATH":     apiStatsPath,
		"STAX_API_SYSTEMS_PATH":   apiSystemsPath,
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
// `${STAX_DIR}/${STAX_LOCK_FILE}` resolve to their final form, and
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
