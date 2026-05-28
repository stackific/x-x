// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestHandleAPIHello pins the wire shape of /api/hello: 200, JSON
// content type, and a body that carries `message` and the running
// Version. The Version assertion catches a future linker-flag wiring
// regression (if the build started shipping with an empty Version,
// every UI talking to the server would lose its "what binary am I
// hitting" signal).
func TestHandleAPIHello(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, apiHelloPath, http.NoBody)
	handleAPIHello(rec, req)

	res := rec.Result()
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	var body helloResponse
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Message != "hello" {
		t.Fatalf("message = %q, want hello", body.Message)
	}
	if body.Version != Version {
		t.Fatalf("version = %q, want %q", body.Version, Version)
	}
}

// TestReadSystemsForAPI exercises the testable body of handleAPISystems
// directly against a temp registry file: returns id+name pairs in
// ascending id order. The pure shape (path in, slice out, no globals)
// keeps the lookup logic decoupled from the http.Handler so a regression
// in either layer surfaces independently.
func TestReadSystemsForAPI(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "registry.yaml")
	// Two systems, written out-of-order — the sort below proves we
	// don't depend on YAML appearance order.
	body := "systems:\n" +
		"  - id: zeta\n    name: Zeta Service\n" +
		"  - id: alpha\n    name: Alpha Service\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}

	got := readSystemsForAPI(path)
	want := []systemEntry{
		{ID: "alpha", Name: "Alpha Service"},
		{ID: "zeta", Name: "Zeta Service"},
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
	got := readSystemsForAPI(filepath.Join(t.TempDir(), "absent.yaml"))
	if len(got) != 0 {
		t.Fatalf("expected empty slice for missing file, got %+v", got)
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
	for _, page := range []string{"/systems", "/search", "/minibooks", "/essay"} {
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
		{apiHelloPath, `"message":"hello"`},
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
