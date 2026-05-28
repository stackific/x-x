// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"embed"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

// embeddedAgents bundles the entire agents/ tree (skills and per-agent
// config) into the binary at compile time. The `all:` prefix is kept
// because the default embed glob excludes `_`-prefixed entries — `all:`
// overrides that, so any future shared helper directory whose name starts
// with `_` will ship without an extra edit here. The directive must point
// at a path relative to the .go file holding it; keep the on-disk
// `agents/` directory in this same folder or `go build` will fail with
// "pattern matches no files".
//
//go:embed all:agents
var embeddedAgents embed.FS

// agentsTarget returns the absolute path of the materialized agents
// directory under the user's home (~/.x-x/agents). Centralized here so every
// caller in the program agrees on the location — change this one function
// to relocate (e.g. honor an env-var override).
func agentsTarget() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		// os.UserHomeDir only fails when neither $HOME nor any of the
		// platform fallbacks (CSIDL on Windows, getpwuid on POSIX) work.
		// In practice this means a malformed environment — propagate the
		// error rather than guess at a fallback path.
		return "", fmt.Errorf("locate home directory: %w", err)
	}
	return filepath.Join(home, xxHomeDir, agentsEmbedRoot), nil
}

// ensureBundledAgents guarantees ~/.x-x/agents/ exists, writing it from the
// binary's embedded FS when absent. Lazy bootstrap — never refreshes an
// existing directory. The first invocation of any `x-x` command runs this
// so a freshly-installed binary self-seeds without an explicit setup step.
// The opportunistic 24h update check (maybeNotifyUpdate) handles refreshing
// the tree on subsequent runs.
func ensureBundledAgents() error {
	target, err := agentsTarget()
	if err != nil {
		return err
	}
	// os.Stat returning nil → directory exists, nothing to do. We don't
	// also check that it's a directory (vs file) because creating a file
	// at this path would be a deliberate user action and we shouldn't
	// override it silently. If it's the wrong type, downstream operations
	// will fail with a clearer error than a stat-check could provide.
	if _, err := os.Stat(target); err == nil {
		return nil
	}
	return writeBundledAgents(true)
}

// writeBundledAgents writes the binary's embedded agents/ tree to disk at
// ~/.x-x/agents/. When overwrite is true any existing tree is removed first
// so the result is byte-identical to the binary's embed (this is what the
// 24h update-check refresh wants). When overwrite is false the function
// only creates what's missing.
func writeBundledAgents(overwrite bool) error {
	target, err := agentsTarget()
	if err != nil {
		return err
	}
	if overwrite {
		// RemoveAll on a non-existent path returns nil, so this is safe
		// on first install too. On Windows, RemoveAll handles read-only
		// attributes itself; we don't need to chmod first.
		if err := os.RemoveAll(target); err != nil {
			return fmt.Errorf("remove %s: %w", target, err)
		}
	}
	// Create the *parent* (~/.x-x) — the walk below creates `target`
	// itself when it visits the embed root. MkdirAll is idempotent.
	// 0o700 is honored on POSIX; Windows ignores it and the dir inherits
	// the user-profile ACL, which is already user-restrictive by default.
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return fmt.Errorf("create %s: %w", filepath.Dir(target), err)
	}

	// Walk the embedded FS depth-first. fs.WalkDir does NOT follow
	// symlinks (embeds can't contain real symlinks anyway, but worth
	// noting) and visits parents before children, which means MkdirAll
	// for parents has already created the destination by the time we
	// reach each file.
	return fs.WalkDir(embeddedAgents, agentsEmbedRoot, func(srcPath string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			// Propagate any walk-time error (e.g. a corrupted embed)
			// rather than swallow it — at write time we want to fail
			// loud so the user knows the install is incomplete.
			return walkErr
		}
		// Translate embed-relative path "agents/foo/bar" → "<target>/foo/bar".
		// We strip the agentsEmbedRoot prefix so that ~/.x-x/agents/ is the
		// new root, mirroring the on-disk layout of the source tree.
		rel, err := filepath.Rel(agentsEmbedRoot, srcPath)
		if err != nil {
			return err
		}
		// Skip repo-only metadata that doesn't belong in the user's
		// on-disk tree. agents/README.md is for contributors browsing the
		// repo on GitHub — shipping it to ~/.x-x/agents/README.md just
		// confuses end users and clutters their home.
		if !d.IsDir() && skipFromEmbed[rel] {
			return nil
		}
		destPath := filepath.Join(target, rel)
		if d.IsDir() {
			// Create the directory and return — files inside it will be
			// visited by subsequent walk callbacks.
			return os.MkdirAll(destPath, 0o700)
		}
		// Regular file — defer the actual byte copy to a helper so the
		// walk callback stays small and readable.
		return copyEmbeddedFile(srcPath, destPath)
	})
}

// copyEmbeddedFile opens one file in the embed.FS and writes it to disk.
// Named return on retErr is used so the deferred Close on the dest file
// can promote a close failure into the returned error — important because
// some filesystems only report write errors on close, not during io.Copy.
func copyEmbeddedFile(srcPath, destPath string) (retErr error) {
	// Open the source from the embed.FS. This is a memory read, not a
	// disk operation — embedded files live in the binary's read-only data.
	src, err := embeddedAgents.Open(srcPath)
	if err != nil {
		return fmt.Errorf("open embedded %s: %w", srcPath, err)
	}
	// Source is read-only and Close() on an embedded file never fails in
	// practice, so discarding the error here is safe.
	defer func() { _ = src.Close() }()

	// Ensure the destination directory exists. The walk callback already
	// creates intermediate directories when it visits them, but if the
	// embed contains a file whose parent dir entry was filtered out for
	// any reason, this guard makes us resilient.
	if err := os.MkdirAll(filepath.Dir(destPath), 0o700); err != nil {
		return fmt.Errorf("create %s: %w", filepath.Dir(destPath), err)
	}
	// O_TRUNC ensures we overwrite cleanly when force=true on materialize
	// already deleted the parent (re-creation case) AND when an unrelated
	// stale file happens to occupy this path. 0o600 keeps perms tight.
	dest, err := os.OpenFile(destPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600) // #nosec G304 -- destPath built from agentsTarget + embed-relative path.
	if err != nil {
		return fmt.Errorf("create %s: %w", destPath, err)
	}
	// Close-via-defer that promotes the close error if no earlier error
	// won. This is the standard "defer Close on a writer" pattern in Go.
	defer func() {
		if cerr := dest.Close(); retErr == nil {
			retErr = cerr
		}
	}()

	if _, err := io.Copy(dest, src); err != nil {
		return fmt.Errorf("write %s: %w", destPath, err)
	}
	return nil
}
