// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestHandleAPIStats pins the wire shape of /api/stats: 200, JSON
// content type, and a body that carries the running Version plus the
// system and scope totals. The Version assertion catches a future
// linker-flag wiring regression. Counts default to zero for a cwd
// with no project, matching the home page's "0 systems / 0 scopes"
// empty state.
func TestHandleAPIStats(t *testing.T) {
	chdir(t, t.TempDir())
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, apiStatsPath, http.NoBody)
	handleAPIStats(rec, req)

	res := rec.Result()
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	var body statsResponse
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Version != Version {
		t.Fatalf("version = %q, want %q", body.Version, Version)
	}
	if body.Systems != 0 || body.Scopes != 0 {
		t.Fatalf("expected zero counts on an empty cwd, got %+v", body)
	}
}

// TestHandleAPIStats_CountsSystemsAndScopes pins the populated path:
// when cwd holds a registry + scope file, the response counts match
// the on-disk reality so the home page renders the right summary.
func TestHandleAPIStats_CountsSystemsAndScopes(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	seedDetailFixture(t, dir,
		"systems:\n  - id: auth\n    name: Auth Service\n  - id: billing\n    name: Billing\n",
		map[string]string{
			"0001-add-pkce.md":  "---\ntitle: Add PKCE\nstatus: valid\nsystems: [auth]\ncreated: 2026-01-10T12:00:00Z\n---\n\n## Goal\nG.\n",
			"0002-proration.md": "---\ntitle: Proration\nstatus: valid\nsystems: [billing]\ncreated: 2026-02-01T09:30:00Z\n---\n\n## Goal\nG.\n",
		},
	)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, apiStatsPath, http.NoBody)
	handleAPIStats(rec, req)

	var body statsResponse
	if err := json.NewDecoder(rec.Result().Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Systems != 2 {
		t.Fatalf("systems = %d, want 2", body.Systems)
	}
	if body.Scopes != 2 {
		t.Fatalf("scopes = %d, want 2", body.Scopes)
	}
}

// TestReadSystemsForAPI exercises the testable body of handleAPISystems
// directly: returns id+name+scopes triples in ascending id order, with
// the scopes count tallied from scope file in the same directory. The
// pure shape (path in, slice out, no globals) keeps the lookup logic
// decoupled from the http.Handler so a regression in either layer
// surfaces independently.
func TestReadSystemsForAPI(t *testing.T) {
	dir := t.TempDir()
	staxPath := filepath.Join(dir, staxDir)
	if err := os.MkdirAll(staxPath, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// Two systems, written out-of-order — the sort below proves we
	// don't depend on YAML appearance order.
	registry := "systems:\n" +
		"  - id: zeta\n    name: Zeta Service\n" +
		"  - id: alpha\n    name: Alpha Service\n"
	if err := os.WriteFile(filepath.Join(staxPath, staxSystemsFile), []byte(registry), 0o600); err != nil {
		t.Fatalf("seed registry: %v", err)
	}
	// Seed three scopes: two declaring `alpha`, one declaring `zeta`.
	// Asserts the per-system tally is correct and that a scope can
	// contribute to more than one system at once.
	scopes := map[string]string{
		"0001-alpha-only.md":     "---\ntitle: A\nstatus: valid\nsystems: [alpha]\ncreated: 2026-01-01T00:00:00Z\n---\n\n## Goal\nG.\n",
		"0002-alpha-and-zeta.md": "---\ntitle: B\nstatus: valid\nsystems: [alpha, zeta]\ncreated: 2026-01-02T00:00:00Z\n---\n\n## Goal\nG.\n",
		"0003-zeta-broken.md":    "no frontmatter — must be ignored\n",
	}
	for name, body := range scopes {
		if err := os.WriteFile(filepath.Join(staxPath, name), []byte(body), 0o600); err != nil {
			t.Fatalf("seed scope %s: %v", name, err)
		}
	}

	got := readSystemsForAPI(staxPath)
	want := []systemEntry{
		{ID: "alpha", Name: "Alpha Service", Scopes: 2},
		{ID: "zeta", Name: "Zeta Service", Scopes: 1},
	}
	if len(got) != len(want) {
		t.Fatalf("len = %d, want %d (%+v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got[%d] = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// TestReadSystemsForAPI_Missing pins the empty-list-on-missing-file
// contract. A directory without .stax/_data_systems.yaml is a valid
// state (no project, or fresh init) — the API must not surface it as
// an error.
func TestReadSystemsForAPI_Missing(t *testing.T) {
	got := readSystemsForAPI(filepath.Join(t.TempDir(), "absent"))
	if len(got) != 0 {
		t.Fatalf("expected empty slice for missing staxDir, got %+v", got)
	}
}

// TestHandleAPISystems_HappyPath drives the full handler against a
// chdir'd temp directory holding a seeded .stax/_data_systems.yaml.
// The handler reads from cwd, so chdir is the test's job — same
// pattern handleAPISystems would observe in production after runDefault
// has honored --cwd.
func TestHandleAPISystems_HappyPath(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	staxPath := filepath.Join(dir, staxDir)
	if err := os.MkdirAll(staxPath, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := "systems:\n  - id: auth\n    name: Auth Service\n"
	if err := os.WriteFile(filepath.Join(staxPath, staxSystemsFile), []byte(body), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, apiSystemsPath, http.NoBody)
	handleAPISystems(rec, req)

	res := rec.Result()
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	var parsed systemsResponse
	if err := json.NewDecoder(res.Body).Decode(&parsed); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(parsed.Systems) != 1 {
		t.Fatalf("systems len = %d, want 1 (%+v)", len(parsed.Systems), parsed.Systems)
	}
	got := parsed.Systems[0]
	if got.ID != "auth" || got.Name != "Auth Service" {
		t.Fatalf("got = %+v, want {auth, Auth Service}", got)
	}
}

// TestHandleAPISystems_NoProjectReturnsEmpty pins the "not-a-project"
// branch: cwd has no .stax/, /api/systems must still answer 200 with
// an empty array. From a UI's point of view "no project here" is a
// normal state, not an error.
func TestHandleAPISystems_NoProjectReturnsEmpty(t *testing.T) {
	chdir(t, t.TempDir())
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, apiSystemsPath, http.NoBody)
	handleAPISystems(rec, req)

	res := rec.Result()
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	var parsed systemsResponse
	if err := json.NewDecoder(res.Body).Decode(&parsed); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if parsed.Systems == nil {
		t.Fatalf("systems = nil, want empty slice for JSON marshaling")
	}
	if len(parsed.Systems) != 0 {
		t.Fatalf("expected empty list, got %+v", parsed.Systems)
	}
}

// seedDetailFixture writes a .stax/ tree containing the registry and the
// supplied scope file. The scope body is wrapped in title/status/systems/
// created frontmatter using the args, so tests can pin specific values
// without hand-rolling the YAML. Returns the staxDir for assertions
// that need it.
func seedDetailFixture(t *testing.T, dir, registry string, scopes map[string]string) string {
	t.Helper()
	staxPath := filepath.Join(dir, staxDir)
	if err := os.MkdirAll(staxPath, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(staxPath, staxSystemsFile), []byte(registry), 0o600); err != nil {
		t.Fatalf("seed registry: %v", err)
	}
	for name, body := range scopes {
		if err := os.WriteFile(filepath.Join(staxPath, name), []byte(body), 0o600); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	return staxPath
}

// TestReadSystemDetail_HappyPath exercises the pure body of the detail
// branch: a known id returns its display name plus every scope whose
// frontmatter `systems:` array contains the id, with each scope's
// markdown body rendered to HTML. Scopes that target a different system
// are excluded.
func TestReadSystemDetail_HappyPath(t *testing.T) {
	dir := t.TempDir()
	registry := "systems:\n" +
		"  - id: auth\n    name: Auth Service\n" +
		"  - id: billing\n    name: Billing\n"
	scopes := map[string]string{
		"0001-add-pkce.md": "---\n" +
			"title: Add PKCE to mobile flow\n" +
			"status: valid\n" +
			"systems: [auth]\n" +
			"created: 2026-01-10T12:00:00Z\n" +
			"---\n\n" +
			"## Goal\nGate mobile sign-in on PKCE.\n",
		"0002-bill-proration.md": "---\n" +
			"title: Apply proration on upgrade\n" +
			"status: valid\n" +
			"systems: [billing]\n" +
			"created: 2026-02-01T09:30:00Z\n" +
			"---\n\n" +
			"## Goal\nCredit unused days.\n",
		"0003-auth-rotate.md": "---\n" +
			"title: Rotate session tokens daily\n" +
			"status: valid\n" +
			"systems: [auth]\n" +
			"created: 2026-03-15T16:45:00Z\n" +
			"---\n\n" +
			"## Goal\nShrink the stolen-token window.\n",
	}
	staxPath := seedDetailFixture(t, dir, registry, scopes)

	got, ok := readSystemDetail(staxPath, "auth")
	if !ok {
		t.Fatalf("readSystemDetail returned false for known id")
	}
	if got.ID != "auth" || got.Name != "Auth Service" {
		t.Fatalf("id/name mismatch: %+v", got)
	}
	if len(got.Scopes) != 2 {
		t.Fatalf("scopes len = %d, want 2 (%+v)", len(got.Scopes), got.Scopes)
	}
	// Scopes must come back in filename order DESCENDING (newest first
	// because the zero-padded prefix is sequential).
	if got.Scopes[0].Slug != "0003-auth-rotate" || got.Scopes[1].Slug != "0001-add-pkce" {
		t.Fatalf("scope order wrong: %+v", got.Scopes)
	}
	if got.Scopes[0].Title != "Rotate session tokens daily" {
		t.Fatalf("title = %q, want %q", got.Scopes[0].Title, "Rotate session tokens daily")
	}
	if got.Scopes[0].Status != "valid" {
		t.Fatalf("status = %q, want valid", got.Scopes[0].Status)
	}
	if got.Scopes[0].Created != "2026-03-15T16:45:00Z" {
		t.Fatalf("created = %q, want 2026-03-15T16:45:00Z", got.Scopes[0].Created)
	}
}

// TestReadSystemDetail_UnknownID pins the not-found contract. A slug
// that does not match any entry in .stax/_data_systems.yaml returns
// (_, false) so the handler can translate it into a 404.
func TestReadSystemDetail_UnknownID(t *testing.T) {
	dir := t.TempDir()
	seedDetailFixture(t, dir,
		"systems:\n  - id: auth\n    name: Auth Service\n",
		nil,
	)
	if _, ok := readSystemDetail(filepath.Join(dir, staxDir), "nope"); ok {
		t.Fatalf("expected ok=false for unknown id")
	}
}

// TestReadSystemDetail_KnownButNoScopes pins the empty-scopes branch.
// The id exists in the registry but no scope file declares it — the
// response must still return ok=true with Scopes as an empty (not nil)
// slice so JSON encodes `[]` rather than `null`.
func TestReadSystemDetail_KnownButNoScopes(t *testing.T) {
	dir := t.TempDir()
	staxPath := seedDetailFixture(t, dir,
		"systems:\n  - id: auth\n    name: Auth Service\n",
		map[string]string{
			"0001-billing-only.md": "---\n" +
				"title: Billing only\n" +
				"status: valid\n" +
				"systems: [billing]\n" +
				"created: 2026-01-01T00:00:00Z\n" +
				"---\n\n## Goal\nUnrelated.\n",
		},
	)
	got, ok := readSystemDetail(staxPath, "auth")
	if !ok {
		t.Fatalf("ok=false for known id")
	}
	if got.Scopes == nil {
		t.Fatalf("scopes = nil, want empty slice for JSON marshaling")
	}
	if len(got.Scopes) != 0 {
		t.Fatalf("scopes len = %d, want 0", len(got.Scopes))
	}
}

// TestHandleAPISystems_DetailMode drives the full handler with ?id=
// against a chdir'd temp directory holding a seeded registry and a
// matching scope. Confirms the detail JSON shape and a markdown→HTML
// rendering for the body so a regression in either layer surfaces here.
func TestHandleAPISystems_DetailMode(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	seedDetailFixture(t, dir,
		"systems:\n  - id: auth\n    name: Auth Service\n",
		map[string]string{
			"0001-add-pkce.md": "---\n" +
				"title: Add PKCE\n" +
				"status: valid\n" +
				"systems: [auth]\n" +
				"created: 2026-01-10T12:00:00Z\n" +
				"---\n\n" +
				"## Goal\nWrite PKCE.\n\n" +
				"- [ ] When X, the Auth Service shall Y.\n",
		},
	)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, apiSystemsPath+"?id=auth", http.NoBody)
	handleAPISystems(rec, req)

	res := rec.Result()
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	var parsed systemDetailResponse
	if err := json.NewDecoder(res.Body).Decode(&parsed); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if parsed.ID != "auth" || parsed.Name != "Auth Service" {
		t.Fatalf("id/name mismatch: %+v", parsed)
	}
	if len(parsed.Scopes) != 1 {
		t.Fatalf("scopes len = %d, want 1", len(parsed.Scopes))
	}
	if parsed.Scopes[0].Title != "Add PKCE" {
		t.Fatalf("scopes[0].Title = %q, want %q", parsed.Scopes[0].Title, "Add PKCE")
	}
}

// TestHandleAPISystems_DetailUnknownID pins the 404 path for an id
// that is not declared in the registry. The body is a small JSON
// `{error: "..."}` so the UI can pattern-match on it.
func TestHandleAPISystems_DetailUnknownID(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	seedDetailFixture(t, dir,
		"systems:\n  - id: auth\n    name: Auth Service\n",
		nil,
	)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, apiSystemsPath+"?id=nope", http.NoBody)
	handleAPISystems(rec, req)

	res := rec.Result()
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", res.StatusCode)
	}
	var parsed apiErrorResponse
	if err := json.NewDecoder(res.Body).Decode(&parsed); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if parsed.Error == "" {
		t.Fatalf("error field empty")
	}
}

// TestReadScopeDetail_HasOpenTasks pins the open-task signal that the
// `/scope?id=` page uses to tint the title flag icon `primary-text`,
// matching the per-row icon convention on `/scopes`. A `- [ ]` marker
// anywhere in the markdown body flips the flag; a body without it
// reports false. Mirrors how readScopeForAPI populates the same field
// on scopeSummary rows (server.go:428).
func TestReadScopeDetail_HasOpenTasks(t *testing.T) {
	dir := t.TempDir()
	staxPath := seedDetailFixture(t, dir,
		"systems:\n  - id: auth\n    name: Auth Service\n",
		map[string]string{
			"0001-open.md": "---\n" +
				"title: Has open task\n" +
				"status: valid\n" +
				"systems: [auth]\n" +
				"created: 2026-01-10T12:00:00Z\n" +
				"---\n\n" +
				"## Tasks\n- [ ] Outstanding work.\n",
			"0002-closed.md": "---\n" +
				"title: All done\n" +
				"status: valid\n" +
				"systems: [auth]\n" +
				"created: 2026-01-11T12:00:00Z\n" +
				"---\n\n" +
				"## Tasks\n- [x] Already shipped.\n",
		},
	)

	cases := []struct {
		slug string
		want bool
	}{
		{"0001-open", true},
		{"0002-closed", false},
	}
	for _, c := range cases {
		t.Run(c.slug, func(t *testing.T) {
			got, ok := readScopeDetail(staxPath, c.slug)
			if !ok {
				t.Fatalf("readScopeDetail(%q) returned false", c.slug)
			}
			if got.HasOpenTasks != c.want {
				t.Fatalf("hasOpenTasks = %v, want %v", got.HasOpenTasks, c.want)
			}
		})
	}
}

// TestReadScopesForAPI_SortedByCreatedDesc pins that the /api/scopes
// list comes back ordered by frontmatter `created` descending — newest
// first — even when the filename slug's numeric prefix disagrees with
// the date. The fixture intentionally inverts prefix vs. created: the
// higher-prefixed file is older. A sort-by-slug regression would put
// the older plan first; this test catches that.
func TestReadScopesForAPI_SortedByCreatedDesc(t *testing.T) {
	dir := t.TempDir()
	staxPath := seedDetailFixture(t, dir, "systems:\n",
		map[string]string{
			"0001-newer-with-low-prefix.md": "---\n" +
				"title: Newer but lower prefix\n" +
				"status: valid\n" +
				"systems: []\n" +
				"created: 2026-03-15T16:45:00Z\n" +
				"---\n\n## Goal\nG.\n",
			"0002-older-with-high-prefix.md": "---\n" +
				"title: Older but higher prefix\n" +
				"status: valid\n" +
				"systems: []\n" +
				"created: 2026-01-10T12:00:00Z\n" +
				"---\n\n## Goal\nG.\n",
		},
	)
	got := readScopesForAPI(staxPath)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2 (%+v)", len(got), got)
	}
	if got[0].Slug != "0001-newer-with-low-prefix" {
		t.Fatalf("got[0].Slug = %q, want %q (sort must honor `created:` desc, not filename desc)",
			got[0].Slug, "0001-newer-with-low-prefix")
	}
}

// TestReadScopesForAPI_TieBreakBySlugDesc pins the deterministic
// tie-break: when two plans share an identical `created:` timestamp
// (rare but possible — same wall-clock second), the higher-prefix
// slug wins. Matches the old filename-sort behavior so monotonic
// datasets still render identically after the sort key change.
func TestReadScopesForAPI_TieBreakBySlugDesc(t *testing.T) {
	dir := t.TempDir()
	body := "---\ntitle: T\nstatus: valid\nsystems: []\ncreated: 2026-01-10T12:00:00Z\n---\n\n## Goal\nG.\n"
	staxPath := seedDetailFixture(t, dir, "systems:\n",
		map[string]string{
			"0001-low.md":  body,
			"0099-high.md": body,
		},
	)
	got := readScopesForAPI(staxPath)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	if got[0].Slug != "0099-high" {
		t.Fatalf("got[0].Slug = %q, want %q (tie-break on identical created: must prefer higher slug)",
			got[0].Slug, "0099-high")
	}
}

// TestReadSystemDetail_SortedByCreatedDesc mirrors the /api/scopes
// sort assertion against the system-detail handler so a regression in
// only one of the two pure-body functions doesn't slip through.
func TestReadSystemDetail_SortedByCreatedDesc(t *testing.T) {
	dir := t.TempDir()
	staxPath := seedDetailFixture(t, dir,
		"systems:\n  - id: auth\n    name: Auth Service\n",
		map[string]string{
			"0001-newer-low-prefix.md": "---\n" +
				"title: Newer\n" +
				"status: valid\n" +
				"systems: [auth]\n" +
				"created: 2026-03-15T16:45:00Z\n" +
				"---\n\n## Goal\nG.\n",
			"0002-older-high-prefix.md": "---\n" +
				"title: Older\n" +
				"status: valid\n" +
				"systems: [auth]\n" +
				"created: 2026-01-10T12:00:00Z\n" +
				"---\n\n## Goal\nG.\n",
		},
	)
	got, ok := readSystemDetail(staxPath, "auth")
	if !ok {
		t.Fatalf("readSystemDetail returned false for known id")
	}
	if len(got.Scopes) != 2 {
		t.Fatalf("scopes len = %d, want 2", len(got.Scopes))
	}
	if got.Scopes[0].Slug != "0001-newer-low-prefix" {
		t.Fatalf("plans[0].Slug = %q, want %q (sort must honor `created:` desc, not filename desc)",
			got.Scopes[0].Slug, "0001-newer-low-prefix")
	}
}

// TestNewServerMux_ServesEmbeddedFrontend exercises the catch-all
// static handler: a GET on `/index.html` reads
// `frontend/dist/index.html` from the embed and returns it. Pins the
// embed wiring so a future `frontend/dist` move (or a vite output-dir
// rename) surfaces as a 404 / empty body here instead of silently
// breaking the web UI.
func TestNewServerMux_ServesEmbeddedFrontend(t *testing.T) {
	srv := httptest.NewServer(newServerMux())
	t.Cleanup(srv.Close)
	res, err := http.Get(srv.URL + "/index.html") // #nosec G107 -- srv.URL is httptest.
	if err != nil {
		t.Fatalf("GET /index.html: %v", err)
	}
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (frontend/dist/index.html must exist)", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("Content-Type = %q, want text/html prefix", ct)
	}
	buf := make([]byte, 512)
	n, _ := res.Body.Read(buf)
	body := strings.ToLower(string(buf[:n]))
	if !strings.Contains(body, "<html") && !strings.Contains(body, "<!doctype") {
		t.Fatalf("body does not look like HTML: %q", string(buf[:n]))
	}
}

// TestNewServerMux_CleanURLs pins the `.html` extension fallback that
// handleFrontend adds on top of net/http's bare FileServer. The Vite
// dist tree ships flat `*.html` files at the root, so a clean URL like
// `/systems` MUST resolve to `systems.html` — without this fallback
// every page except `/` would 404, and a regression here would silently
// break navigation across the multi-page UI.
func TestNewServerMux_CleanURLs(t *testing.T) {
	srv := httptest.NewServer(newServerMux())
	t.Cleanup(srv.Close)
	for _, page := range []string{"/systems", "/system", "/search", "/scopes", "/scope"} {
		t.Run(page, func(t *testing.T) {
			res, err := http.Get(srv.URL + page) // #nosec G107 -- srv.URL is httptest.
			if err != nil {
				t.Fatalf("GET %s: %v", page, err)
			}
			defer func() { _ = res.Body.Close() }()
			if res.StatusCode != http.StatusOK {
				t.Fatalf("GET %s: status = %d, want 200 (clean-URL fallback to %s.html must work)",
					page, res.StatusCode, page)
			}
			if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
				t.Fatalf("GET %s: Content-Type = %q, want text/html prefix", page, ct)
			}
		})
	}
}

// TestMarkdownRenderer_PinsHeadingsToH6 pins the forceH6Headings AST
// transformer: every markdown heading level (`#` … `######`) MUST
// render as <h6>. Scopes declare `## Goal`, `## Approach`, `## Tasks`
// in the body, and the page chrome (chip, breadcrumb, page title)
// already supplies the visual hierarchy — without this pin, an
// accidental drop of the transformer would re-flood the detail page
// with oversized headings.
func TestMarkdownRenderer_PinsHeadingsToH6(t *testing.T) {
	src := strings.Join([]string{
		"# H1 heading",
		"## H2 heading",
		"### H3 heading",
		"#### H4 heading",
		"##### H5 heading",
		"###### H6 heading",
		"",
		"Body paragraph.",
	}, "\n")
	var buf bytes.Buffer
	if err := markdownRenderer.Convert([]byte(src), &buf); err != nil {
		t.Fatalf("convert: %v", err)
	}
	html := buf.String()
	for _, want := range []string{"H1 heading", "H2 heading", "H3 heading", "H4 heading", "H5 heading", "H6 heading"} {
		idx := strings.Index(html, want)
		if idx < 0 {
			t.Fatalf("rendered HTML missing %q: %s", want, html)
		}
		// Walk back to find the opening tag wrapping this heading text.
		opener := strings.LastIndex(html[:idx], "<h")
		if opener < 0 {
			t.Fatalf("no opening <h tag before %q in HTML: %s", want, html)
		}
		if !strings.HasPrefix(html[opener:], "<h6") {
			t.Fatalf("heading %q rendered with non-h6 tag: %q (HTML: %s)",
				want, html[opener:opener+4], html)
		}
	}
	for _, banned := range []string{"<h1", "<h2", "<h3", "<h4", "<h5"} {
		if strings.Contains(html, banned) {
			t.Fatalf("rendered HTML must not carry %s, got: %s", banned, html)
		}
	}
}

// TestHandleFrontend_WOFF2HasImmutableCacheControl pins the long-lived
// caching contract for embedded font assets. Material Symbols
// Outlined sits behind a stable filename the build doesn't fingerprint,
// so its response must carry `public, max-age=31536000, immutable` to
// avoid a 304 revalidation round trip on every page navigation. The
// negative twin proves the header is narrowed — a request for the
// fingerprint-free HTML root must NOT inherit the long-lived cache, so
// content changes between releases still propagate.
func TestHandleFrontend_WOFF2HasImmutableCacheControl(t *testing.T) {
	srv := httptest.NewServer(newServerMux())
	t.Cleanup(srv.Close)

	cases := []struct {
		name    string
		path    string
		wantHdr string
	}{
		{"woff2 gets immutable", frontendAssetsURLPrefix + "material-symbols-outlined" + woff2Ext, assetImmutableCacheControl},
		{"html stays default", "/index.html", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			res, err := http.Get(srv.URL + c.path) // #nosec G107 -- srv.URL is httptest.
			if err != nil {
				t.Fatalf("GET %s: %v", c.path, err)
			}
			defer func() { _ = res.Body.Close() }()
			if res.StatusCode != http.StatusOK {
				t.Fatalf("status = %d, want 200 (%s must exist in the embed)", res.StatusCode, c.path)
			}
			got := res.Header.Get("Cache-Control")
			if got != c.wantHdr {
				t.Fatalf("Cache-Control = %q, want %q", got, c.wantHdr)
			}
		})
	}
}

// TestNewServerMux_404FallbackServesBrandedPage pins the branded 404
// path: an unknown URL gets `404.html` from the embed back with a 404
// status code. Lets the frontend keep its design language even on the
// error path.
func TestNewServerMux_404FallbackServesBrandedPage(t *testing.T) {
	srv := httptest.NewServer(newServerMux())
	t.Cleanup(srv.Close)
	res, err := http.Get(srv.URL + "/this-page-does-not-exist-anywhere") // #nosec G107 -- srv.URL is httptest.
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("Content-Type = %q, want text/html prefix (404.html should be branded HTML)", ct)
	}
}

// TestNewServerMux_RoutesBothEndpoints is the routing-table pin:
// fetch both API paths through the live mux + httptest.Server so any
// future handler-rename or path-typo surfaces as a 404 here. Uses the
// real mux (not direct handler calls) so the assertion covers the
// HandleFunc registrations too.
func TestNewServerMux_RoutesBothEndpoints(t *testing.T) {
	// Seed a tiny project so /api/systems returns a deterministic body
	// the assertion can pin.
	dir := t.TempDir()
	chdir(t, dir)
	staxPath := filepath.Join(dir, staxDir)
	if err := os.MkdirAll(staxPath, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := "systems:\n  - id: auth\n    name: Auth Service\n"
	if err := os.WriteFile(filepath.Join(staxPath, staxSystemsFile), []byte(body), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}

	srv := httptest.NewServer(newServerMux())
	t.Cleanup(srv.Close)

	cases := []struct {
		path string
		want string
	}{
		{apiStatsPath, fmt.Sprintf(`"version":%q`, Version)},
		{apiSystemsPath, `"id":"auth"`},
	}
	for _, c := range cases {
		t.Run(c.path, func(t *testing.T) {
			res, err := http.Get(srv.URL + c.path) // #nosec G107 -- srv.URL is httptest.
			if err != nil {
				t.Fatalf("GET: %v", err)
			}
			defer func() { _ = res.Body.Close() }()
			if res.StatusCode != http.StatusOK {
				t.Fatalf("status = %d, want 200", res.StatusCode)
			}
			buf := make([]byte, 1024)
			n, _ := res.Body.Read(buf)
			if !strings.Contains(string(buf[:n]), c.want) {
				t.Fatalf("body %q must contain %q", string(buf[:n]), c.want)
			}
		})
	}
}

// reserveFreePort grabs a kernel-assigned port via "127.0.0.1:0",
// closes it, and returns the host:port string. Used by the
// listenWithFallback tests so they exercise the fallback loop against
// arbitrary unused ports instead of the hard-coded 7829 (which a
// developer's running stax server may be holding).
//
// There is a TOCTOU window between Close and the next Listen — the
// kernel could hand the port to someone else. Acceptable for unit
// tests; the alternative (keep the listener and pass it in) would
// defeat the purpose of testing listenWithFallback's bind path.
func reserveFreePort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve free port: %v", err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	return addr
}

// TestListenWithFallbackOn_UsesPreferredPortWhenFree pins the happy
// path: when the requested bind address is free, listenWithFallbackOn
// binds it and returns the matching displayHost URL without printing
// any fallback diagnostic.
func TestListenWithFallbackOn_UsesPreferredPortWhenFree(t *testing.T) {
	bind := reserveFreePort(t)
	var stderr bytes.Buffer
	ln, gotURL, err := listenWithFallbackOn(bind, "localhost", 10, &stderr)
	if err != nil {
		t.Fatalf("listenWithFallbackOn: %v", err)
	}
	defer func() { _ = ln.Close() }()
	_, portStr, _ := net.SplitHostPort(bind)
	wantURL := "http://localhost:" + portStr
	if gotURL != wantURL {
		t.Fatalf("url = %q, want %q (preferred-port URL)", gotURL, wantURL)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty (no fallback diagnostic on happy path)", stderr.String())
	}
}

// TestListenWithFallbackOn_WalksForwardWhenPreferredBusy pins the
// fallback path: a foreign listener already owns the preferred port,
// so listenWithFallbackOn must land on the next free port and print a
// single-line stderr explainer. The returned URL keeps displayHost
// (`localhost` here) and carries the actually-bound port.
func TestListenWithFallbackOn_WalksForwardWhenPreferredBusy(t *testing.T) {
	bind := reserveFreePort(t)
	squatter, err := net.Listen("tcp", bind)
	if err != nil {
		t.Fatalf("squat preferred port: %v", err)
	}
	defer func() { _ = squatter.Close() }()

	var stderr bytes.Buffer
	ln, gotURL, err := listenWithFallbackOn(bind, "localhost", 10, &stderr)
	if err != nil {
		t.Fatalf("listenWithFallbackOn: %v", err)
	}
	defer func() { _ = ln.Close() }()

	_, basePortStr, _ := net.SplitHostPort(bind)
	basePort, _ := strconv.Atoi(basePortStr)
	wantURL := fmt.Sprintf("http://localhost:%d", basePort+1)
	if gotURL != wantURL {
		t.Fatalf("url = %q, want %q (first fallback port)", gotURL, wantURL)
	}
	if !strings.Contains(stderr.String(), fmt.Sprintf("port %d already in use", basePort)) {
		t.Fatalf("stderr = %q, want fallback diagnostic mentioning preferred port", stderr.String())
	}
}

// TestListenWithFallbackOn_AllPortsBusy pins the exhausted-range path:
// every port in the candidate range is held, so listenWithFallbackOn
// returns an error mentioning the range. Uses attempts=2 so the test
// only needs to squat three adjacent ports.
func TestListenWithFallbackOn_AllPortsBusy(t *testing.T) {
	bind := reserveFreePort(t)
	_, basePortStr, _ := net.SplitHostPort(bind)
	basePort, _ := strconv.Atoi(basePortStr)
	const attempts = 2
	var squatters []net.Listener
	defer func() {
		for _, s := range squatters {
			_ = s.Close()
		}
	}()
	for offset := 0; offset <= attempts; offset++ {
		s, lerr := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(basePort+offset)))
		if lerr != nil {
			t.Skipf("could not squat port %d for exhaustion test: %v", basePort+offset, lerr)
		}
		squatters = append(squatters, s)
	}
	_, _, err := listenWithFallbackOn(bind, "localhost", attempts, io.Discard)
	if err == nil {
		t.Fatalf("expected error when every candidate port is held")
	}
	if !strings.Contains(err.Error(), "all in use") {
		t.Fatalf("error %q must mention 'all in use'", err.Error())
	}
}

// TestHandleAPISearch_EmptyQuery pins the no-query contract: the
// handler answers 200 with both arrays empty (not null) and echoes
// the query field as the empty string. Lets the UI treat the
// "type-to-search" state as a normal render rather than an error.
func TestHandleAPISearch_EmptyQuery(t *testing.T) {
	chdir(t, t.TempDir())
	// Whitespace forms encoded so httptest.NewRequest accepts the URL;
	// the handler trims after parsing, so all three land in the
	// no-query branch.
	for _, q := range []string{"", "%20%20%20", "%09%0A"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, apiSearchPath+"?q="+q, http.NoBody)
		handleAPISearch(rec, req)

		var body searchResponse
		if err := json.NewDecoder(rec.Result().Body).Decode(&body); err != nil {
			t.Fatalf("q=%q decode: %v", q, err)
		}
		if body.Scopes == nil || body.Systems == nil {
			t.Fatalf("q=%q expected non-nil empty slices, got %+v", q, body)
		}
		if len(body.Scopes) != 0 || len(body.Systems) != 0 {
			t.Fatalf("q=%q expected empty results, got %+v", q, body)
		}
		if body.Query != "" {
			t.Fatalf("q=%q expected empty echoed query, got %q", q, body.Query)
		}
	}
}

// TestRunSearch pins the substring-match rules across both arrays:
// case-insensitive title / system-id / body matches surface the right
// scope, system id and name matches surface the right system, and
// queries that don't match anywhere return an empty (not nil)
// response. Body match happens last, so the test seeds a scope where
// the only place the needle appears is the markdown body.
func TestRunSearch(t *testing.T) {
	dir := t.TempDir()
	seedDetailFixture(t, dir,
		"systems:\n  - id: auth-service\n    name: Auth Service\n  - id: billing\n    name: Billing\n",
		map[string]string{
			"0001-add-pkce.md":       "---\ntitle: Add PKCE to mobile flow\nstatus: valid\nsystems: [auth-service]\ncreated: 2026-01-10T12:00:00Z\n---\n\n## Goal\nGate mobile sign-in on PKCE.\n",
			"0002-proration.md":      "---\ntitle: Apply proration on upgrade\nstatus: valid\nsystems: [billing]\ncreated: 2026-02-01T09:30:00Z\n---\n\n## Goal\nCredit unused days on scope changes.\n",
			"0003-stripe-webhook.md": "---\ntitle: Retry failed webhooks\nstatus: valid\nsystems: [billing]\ncreated: 2026-03-01T09:00:00Z\n---\n\n## Goal\nA short body that mentions exponential-backoff so a body-only query hits.\n",
		},
	)
	staxPath := filepath.Join(dir, staxDir)

	cases := []struct {
		name        string
		q           string
		wantScopes  []string // slugs we expect, in any order
		wantSystems []string // ids we expect, in any order
	}{
		{"title hit", "PKCE", []string{"0001-add-pkce"}, nil},
		{"system-id hit on scope row", "billing", []string{"0003-stripe-webhook", "0002-proration"}, []string{"billing"}},
		{"body-only hit", "exponential-backoff", []string{"0003-stripe-webhook"}, nil},
		{"system name hit", "auth service", nil, []string{"auth-service"}},
		{"no matches", "this-text-is-nowhere", []string{}, []string{}},
		{"case insensitive", "PRORATION", []string{"0002-proration"}, nil},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := runSearch(staxPath, c.q)
			assertSearchScopes(t, got.Scopes, c.wantScopes)
			assertSearchSystems(t, got.Systems, c.wantSystems)
		})
	}
}

// assertSearchScopes verifies every wanted slug appears in got and
// (when wantSlugs is non-empty) that the counts match. Extracted from
// TestRunSearch to keep its inner case-loop body under the project's
// cognitive-complexity cap.
func assertSearchScopes(t *testing.T, got []scopeListItem, wantSlugs []string) {
	t.Helper()
	gotSlugs := make(map[string]bool, len(got))
	for _, s := range got {
		gotSlugs[s.Slug] = true
	}
	for _, want := range wantSlugs {
		if !gotSlugs[want] {
			t.Errorf("expected scope %q in results, got %v", want, gotSlugs)
		}
	}
	if len(wantSlugs) > 0 && len(got) != len(wantSlugs) {
		t.Errorf("scope count = %d, want %d (%v)", len(got), len(wantSlugs), got)
	}
}

// assertSearchSystems mirrors assertSearchScopes for the systems
// slice: every wanted id must appear, and an explicit empty want
// (non-nil zero-length slice) means no system hits are allowed.
func assertSearchSystems(t *testing.T, got []systemEntry, wantIDs []string) {
	t.Helper()
	gotIDs := make(map[string]bool, len(got))
	for _, s := range got {
		gotIDs[s.ID] = true
	}
	for _, want := range wantIDs {
		if !gotIDs[want] {
			t.Errorf("expected system %q in results, got %v", want, gotIDs)
		}
	}
	if wantIDs != nil && len(wantIDs) == 0 && len(got) != 0 {
		t.Errorf("expected no system hits, got %+v", got)
	}
}
