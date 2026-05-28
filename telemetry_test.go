// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// telemetryHit captures the salient bits of one POST: the parsed JSON
// body and the request method + Content-Type so tests can assert on
// both the wire format AND the payload.
type telemetryHit struct {
	method      string
	contentType string
	body        map[string]string
}

// telemetryProbe is a one-shot httptest.Server that records every
// request. Each test gets a fresh probe so request ordering across
// tests can never leak.
type telemetryProbe struct {
	server *httptest.Server
	mu     sync.Mutex
	hits   []telemetryHit
}

func newTelemetryProbe(t *testing.T) *telemetryProbe {
	t.Helper()
	p := &telemetryProbe{}
	p.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		_ = r.Body.Close()
		var body map[string]string
		_ = json.Unmarshal(raw, &body)
		p.mu.Lock()
		p.hits = append(p.hits, telemetryHit{
			method:      r.Method,
			contentType: r.Header.Get("Content-Type"),
			body:        body,
		})
		p.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(p.server.Close)
	return p
}

// pointTelemetryAt redirects every track() call in the running test
// at the given httptest server URL. Uses t.Setenv so the variable
// is restored after the test regardless of pass/fail.
func pointTelemetryAt(t *testing.T, endpoint string) {
	t.Helper()
	t.Setenv(telemetryEnvEndpoint, endpoint)
	// Always ensure opt-out vars are unset before we try to track, so
	// a test inherits a "telemetry enabled" baseline regardless of
	// what the developer's shell or a previous test left behind.
	t.Setenv(telemetryEnvDoNotTrack, "")
	t.Setenv(telemetryEnvDisable, "")
}

func TestTelemetry_TrackFiresAndIncludesStandardParams(t *testing.T) {
	probe := newTelemetryProbe(t)
	pointTelemetryAt(t, probe.server.URL)

	track("init", telemetryEvent{"scope": "project", "agents": "claude,codex"})
	flushTelemetry()

	probe.mu.Lock()
	defer probe.mu.Unlock()
	if len(probe.hits) != 1 {
		t.Fatalf("expected 1 ping, got %d", len(probe.hits))
	}
	got := probe.hits[0]
	if got.method != http.MethodPost {
		t.Errorf("method = %q, want POST", got.method)
	}
	if got.contentType != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got.contentType)
	}
	for _, want := range []struct{ key, val string }{
		{"event", "init"},
		{"scope", "project"},
		{"agents", "claude,codex"},
		{"v", Version},
	} {
		if got.body[want.key] != want.val {
			t.Errorf("body[%q] = %q, want %q", want.key, got.body[want.key], want.val)
		}
	}
	for _, mustExist := range []string{"os", "arch", "session_id"} {
		if got.body[mustExist] == "" {
			t.Errorf("standard param %q missing from body", mustExist)
		}
	}
}

func TestTelemetry_DoNotTrackSuppresses(t *testing.T) {
	probe := newTelemetryProbe(t)
	pointTelemetryAt(t, probe.server.URL)
	t.Setenv(telemetryEnvDoNotTrack, "1")

	track("init", telemetryEvent{"scope": "user"})
	flushTelemetry()

	probe.mu.Lock()
	defer probe.mu.Unlock()
	if len(probe.hits) != 0 {
		t.Fatalf("DO_NOT_TRACK ignored: %d hits recorded", len(probe.hits))
	}
}

func TestTelemetry_DisableTelemetrySuppresses(t *testing.T) {
	probe := newTelemetryProbe(t)
	pointTelemetryAt(t, probe.server.URL)
	t.Setenv(telemetryEnvDisable, "1")

	track("init", telemetryEvent{"scope": "user"})
	flushTelemetry()

	probe.mu.Lock()
	defer probe.mu.Unlock()
	if len(probe.hits) != 0 {
		t.Fatalf("DISABLE_TELEMETRY ignored: %d hits recorded", len(probe.hits))
	}
}

func TestTelemetry_ReservedKeysNotOverwritten(t *testing.T) {
	probe := newTelemetryProbe(t)
	pointTelemetryAt(t, probe.server.URL)

	// Caller tries to spoof the standard floor. track() must ignore
	// those keys and emit the real values.
	track("init", telemetryEvent{
		"event":      "spoofed",
		"v":          "v9.9.9",
		"os":         "??",
		"arch":       "??",
		"session_id": "spoofed",
		"ci":         "spoofed",
		"scope":      "project",
	})
	flushTelemetry()

	probe.mu.Lock()
	defer probe.mu.Unlock()
	if len(probe.hits) != 1 {
		t.Fatalf("expected 1 hit, got %d", len(probe.hits))
	}
	got := probe.hits[0].body
	if got["event"] != "init" {
		t.Errorf("event spoofed: %q", got["event"])
	}
	if got["v"] != Version {
		t.Errorf("v spoofed: %q", got["v"])
	}
	if got["os"] == "??" {
		t.Errorf("os spoofed")
	}
	if got["session_id"] == "spoofed" {
		t.Errorf("session_id spoofed")
	}
	if got["scope"] != "project" {
		t.Errorf("legitimate event-specific key dropped: scope=%q", got["scope"])
	}
}

func TestTelemetry_CIDetection(t *testing.T) {
	probe := newTelemetryProbe(t)
	pointTelemetryAt(t, probe.server.URL)
	// Clear every CI env var so we control the baseline. Iterate the
	// same list the production code checks.
	for _, k := range []string{
		"CI", "GITHUB_ACTIONS", "GITLAB_CI", "CIRCLECI",
		"TRAVIS", "BUILDKITE", "JENKINS_URL", "TEAMCITY_VERSION",
	} {
		t.Setenv(k, "")
	}
	t.Setenv("GITHUB_ACTIONS", "true")

	track("init", telemetryEvent{})
	flushTelemetry()

	probe.mu.Lock()
	defer probe.mu.Unlock()
	if len(probe.hits) != 1 {
		t.Fatalf("expected 1 hit, got %d", len(probe.hits))
	}
	if probe.hits[0].body["ci"] != "1" {
		t.Errorf("ci flag missing under GITHUB_ACTIONS=true: %q", probe.hits[0].body["ci"])
	}
}
