// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

// This file owns the bidirectional JSON-config operations between the
// bundled per-agent files under ~/.x-x/agents/<agent>/ and the user's
// copies under <scopeRoot>/<configRel>/. Two directions live side-by-side
// so the install/uninstall symmetry is visible at a glance:
//
//   Forward (install path, called from runInit → installForTarget):
//     installAgentConfig → installOneAgentConfigFile → mergeJSONFile →
//     mergeJSON → {mergeJSONMaps, mergeJSONArrays} → jsonContainsDeepEqual
//
//   Reverse (un-merge path, called from runSkillRemove):
//     removeBundledHooksIn → collectHookUnmerges → buildHookUnmerge →
//     subtractHooks → subtractEventArray → jsonContainsDeepEqual
//
// jsonDeepEqual and jsonContainsDeepEqual are the shared primitives both
// directions depend on. Keeping the merge code in init.go (where it
// originally lived) created a smell where skill.go's un-merge had to
// reach across files for jsonDeepEqual; that smell goes away once the
// pair lives together.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// installAgentConfig walks src (e.g. ~/.x-x/agents/claude/) and installs
// each file under dest (e.g. ~/.claude/) preserving the relative path.
// Behavior depends on whether the destination already exists AND its
// file extension:
//
//   - Destination absent → copy the bundle's bytes. Config files are
//     ALWAYS copies, even in user-scope POSIX installs where skills get
//     symlinked. The reason: writing through a symlink mutates the
//     bundled file under ~/.x-x/agents/, which corrupts the embed
//     materialization for every project that points at it.
//   - Destination exists as a stale symlink (from an older x-x that did
//     symlink config files) → remove and treat as absent. We created it,
//     so it's safe to remove.
//   - Destination exists AND src has extension configJSONExt → deep-merge
//     the bundled JSON into the existing file. Existing scalar values win
//     (so user edits like a custom model name are preserved); bundled
//     keys missing on the existing side are added (so freshly-shipped
//     hooks land for users who already had a partial settings.json); array
//     entries are unioned by deep equality (so the standard hook entries
//     are appended without duplicating the user's own).
//   - Destination exists AND src is anything else → skip with a "skipping"
//     log. We don't have a merger for TOML/YAML yet, so the conservative
//     default keeps user customizations intact.
//
// Rationale: prior to the JSON merge path, `x-x init` would skip every
// existing config file outright. That left users who'd hand-edited a
// settings.json without our hooks no way to get them short of deleting
// the file. The merge path makes the install additive — re-running init
// surgically lands x-x defaults into an existing file rather than asking
// the user to throw their config away.
func installAgentConfig(src, dest string) error {
	if err := os.MkdirAll(dest, 0o700); err != nil {
		return err
	}
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			// Walk visits dirs but we only act on files — the MkdirAll
			// below covers any nested directories that need to be created.
			return nil
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		return installOneAgentConfigFile(path, filepath.Join(dest, rel), rel)
	})
}

// installOneAgentConfigFile carries the per-file dispatch for
// installAgentConfig's walk callback. Separated so the walker stays
// short and the policy table (symlink → drop, .json → merge, other →
// skip, missing → copy) reads as a single switch.
func installOneAgentConfigFile(srcPath, destPath, rel string) error {
	info, statErr := os.Lstat(destPath)
	if statErr != nil {
		// Destination absent — fresh copy. Walk's parent-creation passes
		// usually already made the dir, but MkdirAll keeps the function
		// self-contained if a caller ever invokes it outside the walk.
		if err := os.MkdirAll(filepath.Dir(destPath), 0o700); err != nil {
			return err
		}
		return copyFile(srcPath, destPath)
	}
	switch {
	case info.Mode()&os.ModeSymlink != 0:
		// Leftover from an older x-x that materialized config files as
		// symlinks. Drop the link so we don't write through to the
		// bundle on the fresh-copy fallthrough below.
		if err := os.Remove(destPath); err != nil {
			fmt.Fprintf(os.Stderr, "    config %s: remove stale symlink: %v\n", rel, err)
			return nil
		}
		if err := os.MkdirAll(filepath.Dir(destPath), 0o700); err != nil {
			return err
		}
		return copyFile(srcPath, destPath)
	case strings.EqualFold(filepath.Ext(destPath), configJSONExt):
		if mErr := mergeJSONFile(srcPath, destPath); mErr != nil {
			// Merge failures are non-fatal: a malformed user file or a
			// (developer-bug) malformed bundled file would otherwise
			// strand the install. Leave the user's content untouched
			// and surface the reason so they can act.
			fmt.Fprintf(os.Stderr, "    config %s: merge failed (%v); leaving existing file untouched\n", rel, mErr)
		}
		return nil
	default:
		fmt.Fprintf(os.Stderr, "    config %s: exists, skipping\n", rel)
		return nil
	}
}

// mergeJSONFile reads the bundled file at bundlePath and the user's file
// at existingPath, deep-merges the two JSON documents under the rules
// documented on mergeJSON, and rewrites existingPath with the result.
//
// Edge cases:
//
//   - A strictly-empty existing file (zero bytes after trim) is treated as
//     `{}`, so a user who touched the file but never put JSON in it gets
//     the bundled content without an error.
//   - Either side failing to parse returns an error so the caller can
//     log and leave the destination alone (see installAgentConfig).
//   - The rewrite uses MarshalIndent with 2-space indent + trailing
//     newline to match the conventional JSON-file format.
func mergeJSONFile(bundlePath, existingPath string) error {
	bundleRaw, err := os.ReadFile(bundlePath) // #nosec G304 -- bundlePath comes from agentsTarget materialized embed.
	if err != nil {
		return fmt.Errorf("read bundle: %w", err)
	}
	existingRaw, err := os.ReadFile(existingPath) // #nosec G304 -- existingPath under user-config dir under chosen scope root.
	if err != nil {
		return fmt.Errorf("read existing: %w", err)
	}
	var bundle, existing any
	if err := json.Unmarshal(bundleRaw, &bundle); err != nil {
		return fmt.Errorf("parse bundle: %w", err)
	}
	if len(bytes.TrimSpace(existingRaw)) == 0 {
		// Treat empty-file as empty-object so the merge produces the
		// bundle's top-level keys rather than failing with a parse error.
		existing = map[string]any{}
	} else if err := json.Unmarshal(existingRaw, &existing); err != nil {
		return fmt.Errorf("parse existing: %w", err)
	}
	merged := mergeJSON(existing, bundle)
	// Fast path: if the merge result is JSON-identical to what's already
	// on disk, leave the bytes alone. This preserves the bundle's source
	// formatting after a fresh copy (so back-to-back `init` runs produce
	// byte-identical files) and keeps user edits' whitespace/key order
	// untouched when no semantic change is needed.
	if jsonDeepEqual(merged, existing) {
		return nil
	}
	body, err := json.MarshalIndent(merged, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal merged: %w", err)
	}
	// Trailing newline matches standard text-file conventions and the
	// bundled file's own format.
	body = append(body, '\n')
	return os.WriteFile(existingPath, body, 0o600)
}

// mergeJSON returns the deep merge of existing and bundled JSON-decoded
// values. Rules:
//
//   - Both objects (map[string]any): keys present in existing keep their
//     value; keys only in bundled are added; shared keys are merged
//     recursively.
//   - Both arrays ([]any): bundled entries are appended to existing in
//     order, skipping any entry that already deep-equals some existing
//     entry. This is what makes the merge idempotent across re-runs.
//   - Either side is nil (JSON null or absent at the call site): the
//     other side wins. This lets a top-level call seed missing keys
//     entirely from the bundle.
//   - Anything else (scalars, type mismatches): existing wins. Never
//     clobber a user-set scalar or rewrite their `[]` into a `{}`.
//
// The function is pure — no I/O — so it can be exercised with hand-built
// values in unit tests without staging files on disk.
func mergeJSON(existing, bundled any) any {
	if existing == nil {
		return bundled
	}
	if bundled == nil {
		return existing
	}
	if eMap, eOK := existing.(map[string]any); eOK {
		if bMap, bOK := bundled.(map[string]any); bOK {
			return mergeJSONMaps(eMap, bMap)
		}
	}
	if eArr, eOK := existing.([]any); eOK {
		if bArr, bOK := bundled.([]any); bOK {
			return mergeJSONArrays(eArr, bArr)
		}
	}
	// Type mismatch or both scalars — existing wins so we never silently
	// rewrite the user's choice.
	return existing
}

// mergeJSONMaps deep-merges two JSON objects under the contract documented
// on mergeJSON: existing keys keep their value, bundled-only keys are
// added, shared keys are recursively merged. Pulled out as its own
// function so mergeJSON's top level reads as one switch over JSON forms.
func mergeJSONMaps(existing, bundled map[string]any) map[string]any {
	out := make(map[string]any, len(existing)+len(bundled))
	for k, v := range existing {
		out[k] = v
	}
	for k, v := range bundled {
		if cur, ok := out[k]; ok {
			out[k] = mergeJSON(cur, v)
		} else {
			out[k] = v
		}
	}
	return out
}

// mergeJSONArrays appends every bundled entry to a copy of existing,
// skipping any that already deep-equal an existing entry. The dedup is
// what makes init re-runs idempotent: applying the same bundle twice
// produces the same array.
func mergeJSONArrays(existing, bundled []any) []any {
	out := make([]any, 0, len(existing)+len(bundled))
	out = append(out, existing...)
	for _, b := range bundled {
		if jsonContainsDeepEqual(existing, b) {
			continue
		}
		out = append(out, b)
	}
	return out
}

// removeBundledHooksIn walks the bundled per-agent config tree at bundleSrc
// (e.g. ~/.x-x/agents/claude/) and, for every bundled .json file, subtracts
// x-x's shipped hook records from the user's counterpart under userDest
// (e.g. ~/.claude/). The bundled file is the live reference for "what we
// shipped" — no install-time snapshot, no marker files.
//
// Scope of removal is intentionally narrow:
//
//   - Only records inside arrays nested under the top-level configHooksKey
//     ("hooks") property are candidates. Everything outside that subtree —
//     other top-level keys, the file's overall structure, user-added event keys
//     under "hooks" — is left exactly as the user wrote it.
//   - A candidate user entry is removed only if it deep-equals an entry the
//     bundle currently ships in the same event-key array. A user-tweaked
//     variant of one of ours fails the equality check and survives. The
//     unit of ownership is the leaf record, not the container.
//   - Empty arrays / empty event-key maps left behind by the subtraction
//     are NOT pruned. We removed entries, not containers; cleanup of
//     empty shells is the user's call.
//
// The file is rewritten only when its content actually changes; identical
// re-runs are byte-no-ops, so calling this on a freshly-installed scope
// and again immediately is safe.
//
// Returns (modifiedRelPaths, skipped). Missing bundleSrc / missing user
// file are silent no-ops — they mirror "agent never had an install at
// this scope" semantics already used by removeOurSkillsIn. Errors
// (read/parse/write) are non-fatal: the offending file is left untouched,
// a diagnostic is written to stderr, and skipped is incremented.
func removeBundledHooksIn(bundleSrc, userDest, agentName string) (modified, skipped int) {
	// Missing source means this agent ships no per-agent config OR the
	// bundle hasn't been materialized yet. Either way nothing to subtract.
	if _, err := os.Stat(bundleSrc); errors.Is(err, os.ErrNotExist) {
		return 0, 0
	}
	pending, walkSkipped := collectHookUnmerges(bundleSrc, userDest)
	skipped += walkSkipped
	if len(pending) == 0 {
		return 0, skipped
	}
	// Header is printed only when there's something to report under it,
	// matching removeOurSkillsIn's silent-on-empty behavior.
	fmt.Printf("  %-13s %s\n", agentName, userDest)
	for _, c := range pending {
		if err := os.WriteFile(c.path, c.body, 0o600); err != nil {
			fmt.Fprintf(os.Stderr, "    %s: write: %v\n", c.rel, err)
			skipped++
			continue
		}
		fmt.Printf("    unmerged %s\n", c.rel)
		modified++
	}
	return modified, skipped
}

// hookUnmerge is one queued un-merge ready to write back. Building these
// up first lets removeBundledHooksIn separate "decide what to change"
// (the WalkDir pass) from "actually mutate the user's filesystem", which
// also gives gocognit a fighting chance.
type hookUnmerge struct {
	rel  string
	body []byte
	path string
}

// collectHookUnmerges walks bundleSrc, computes the un-merged byte form
// of each user file that needs updating, and returns the queue plus a
// count of files skipped due to errors. It does not mutate the user's
// filesystem — the caller writes the queue once the header has been
// printed.
func collectHookUnmerges(bundleSrc, userDest string) (pending []hookUnmerge, skipped int) {
	walkErr := filepath.WalkDir(bundleSrc, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() || !strings.EqualFold(filepath.Ext(path), configJSONExt) {
			return nil
		}
		rel, err := filepath.Rel(bundleSrc, path)
		if err != nil {
			return err
		}
		change, skip, ok := buildHookUnmerge(path, filepath.Join(userDest, rel), rel)
		if skip {
			skipped++
		}
		if ok {
			pending = append(pending, change)
		}
		return nil
	})
	if walkErr != nil {
		fmt.Fprintf(os.Stderr, "    walk %s: %v\n", bundleSrc, walkErr)
	}
	return pending, skipped
}

// buildHookUnmerge is the per-file core of the un-merge: read both sides,
// parse, subtract under configHooksKey, marshal. Returns
//
//	change — the queued write (only meaningful when ok=true)
//	skip   — true when an error was logged and skipped++ should bump
//	ok     — true when a real change is ready to be written
//
// All error paths log to stderr and return ok=false; the caller decides
// whether to bump the skipped counter via the `skip` flag.
func buildHookUnmerge(bundlePath, userPath, rel string) (change hookUnmerge, skip, ok bool) {
	// #nosec G304,G122 -- userPath is built from scopeRoot+agentTargets[*].configRel
	// and bundlePath is yielded by filepath.WalkDir under agentsTarget(); both
	// roots are confined to user-owned, x-x-managed directories under $HOME.
	userRaw, err := os.ReadFile(userPath)
	if errors.Is(err, os.ErrNotExist) {
		return hookUnmerge{}, false, false
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "    %s: read: %v\n", rel, err)
		return hookUnmerge{}, true, false
	}
	bundleRaw, err := os.ReadFile(bundlePath) // #nosec G304,G122 -- see above.
	if err != nil {
		fmt.Fprintf(os.Stderr, "    %s: read bundle: %v\n", rel, err)
		return hookUnmerge{}, true, false
	}
	var bundle, user any
	if err := json.Unmarshal(bundleRaw, &bundle); err != nil {
		// A malformed bundled file is a developer bug, not a user bug.
		// Surface it loudly but leave the user file alone.
		fmt.Fprintf(os.Stderr, "    %s: parse bundle: %v\n", rel, err)
		return hookUnmerge{}, true, false
	}
	if err := json.Unmarshal(userRaw, &user); err != nil {
		fmt.Fprintf(os.Stderr, "    %s: parse user file: %v (leaving untouched)\n", rel, err)
		return hookUnmerge{}, true, false
	}
	uMap, uIsMap := user.(map[string]any)
	bMap, bIsMap := bundle.(map[string]any)
	if !uIsMap || !bIsMap {
		return hookUnmerge{}, false, false
	}
	bHooks, bHas := bMap[configHooksKey]
	uHooks, uHas := uMap[configHooksKey]
	if !bHas || !uHas {
		return hookUnmerge{}, false, false
	}
	newHooks, changed := subtractHooks(uHooks, bHooks)
	if !changed {
		return hookUnmerge{}, false, false
	}
	uMap[configHooksKey] = newHooks
	body, err := json.MarshalIndent(uMap, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "    %s: marshal: %v\n", rel, err)
		return hookUnmerge{}, true, false
	}
	body = append(body, '\n')
	return hookUnmerge{rel: rel, body: body, path: userPath}, false, true
}

// subtractHooks returns user with every leaf record matching a bundled
// record removed from each event-key array. The bool reports whether any
// entry was dropped — callers use it to decide whether the file needs
// rewriting.
//
// Inputs are the *values* of the configHooksKey property on each side
// (typed as map[string]any when JSON-decoded). When either side isn't
// a map, the function is a no-op: type mismatches and unexpected forms
// are preserved untouched rather than silently corrected.
//
// Semantics:
//
//   - For each event key (e.g. "PostToolUse", "Stop") present in bundled,
//     find the user's same-key array and drop entries that deep-equal any
//     bundled entry in that array. Sibling event keys the bundle doesn't
//     ship are left strictly alone.
//   - User entries that don't deep-equal a bundled entry survive — this
//     covers both user-authored siblings AND user-tweaked variants of our
//     records (a changed command, a different matcher).
//   - Empty arrays produced by the subtraction are kept as `[]`. We are
//     subtracting records, not containers; the user can prune empty
//     arrays by hand if they want to.
//
// Pure function — no I/O — so its rules are exercised in unit tests with
// hand-built values, the same structure mergeJSON uses for its tests.
func subtractHooks(user, bundled any) (any, bool) {
	uMap, uIsMap := user.(map[string]any)
	bMap, bIsMap := bundled.(map[string]any)
	if !uIsMap || !bIsMap {
		return user, false
	}
	changed := false
	for eventKey, bVal := range bMap {
		uVal, present := uMap[eventKey]
		if !present {
			continue
		}
		out, dropped := subtractEventArray(uVal, bVal)
		if dropped {
			uMap[eventKey] = out
			changed = true
		}
	}
	return uMap, changed
}

// subtractEventArray drops every entry in user that deep-equals any entry
// in bundled. Both must be []any (the JSON-decoded form of an event-key
// array); otherwise the user value is returned unchanged with dropped=false.
//
// Comparison is whole-record — we never recurse into the user's entries.
// A user-tweaked variant fails the equality check at this level and stays
// in the returned slice. This is what preserves the ownership boundary:
// the leaf record is the unit, never any of its sub-fields.
func subtractEventArray(user, bundled any) (out []any, dropped bool) {
	uArr, uIsArr := user.([]any)
	bArr, bIsArr := bundled.([]any)
	if !uIsArr || !bIsArr {
		// Type mismatch — preserve the user structure verbatim. Return the
		// original (which won't be assigned back since dropped=false).
		return nil, false
	}
	out = make([]any, 0, len(uArr))
	for _, u := range uArr {
		if jsonContainsDeepEqual(bArr, u) {
			continue
		}
		out = append(out, u)
	}
	return out, len(out) != len(uArr)
}

// jsonContainsDeepEqual reports whether any element of pool deep-equals
// candidate. Used by both directions: mergeJSONArrays for dedup on
// install, subtractEventArray for record matching on remove.
func jsonContainsDeepEqual(pool []any, candidate any) bool {
	for _, p := range pool {
		if jsonDeepEqual(p, candidate) {
			return true
		}
	}
	return false
}

// jsonDeepEqual compares two JSON-decoded values for byte-for-byte
// equivalence by round-tripping each through json.Marshal. Go's encoder
// emits map keys in sorted order, which gives a standard form suitable
// for deep equality — `reflect.DeepEqual` would also work, but Marshal
// is robust to any future numeric-type drift between json.Number and
// float64 if a caller swaps decoder modes.
func jsonDeepEqual(a, b any) bool {
	aj, err := json.Marshal(a)
	if err != nil {
		return false
	}
	bj, err := json.Marshal(b)
	if err != nil {
		return false
	}
	return bytes.Equal(aj, bj)
}
