// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.

package main

// telemetry is the anonymous-usage-ping subsystem. The CLI fires named
// events at https://stackific.com/x-x/t over HTTP GET so the backend
// can be a single static endpoint with no body parsing — query-string
// only. Every event carries a small bag of standard params (CLI
// version, OS, arch, CI flag, per-process session id) plus any
// event-specific params the caller supplies.
//
// Privacy posture: opt-out, honored by two env vars — DO_NOT_TRACK
// (industry-standard, consoledonottrack.com) and DISABLE_TELEMETRY
// (project-specific escape hatch). Either set to a non-empty value
// disables every ping. Nothing user-authored is ever sent — no skill
// content, no file paths beyond directory names, no API keys, no
// project paths. The session id is a per-process random UUID, NOT a
// stable machine id, so the backend cannot correlate events across
// separate CLI invocations or across users.
//
// The full event catalog, query-param schema, and backend implementation
// expectations live in docs/internal/telemetry.md.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"net/url"
	"os"
	"runtime"
	"sync"
	"time"
)

// telemetryURL is the production endpoint. Overridable at runtime via
// the X_X_TELEMETRY_ENDPOINT env var so unit tests can point at an
// httptest.Server. The backend at this URL is not yet implemented —
// see docs/internal/telemetry.md for the wire-format contract a
// future backend must honor.
const telemetryURL = "https://stackific.com/x-x/t"

// telemetryHTTPTimeout caps each individual ping. Short enough that a
// hung endpoint never delays a CLI command past noticeable latency,
// long enough that a slow but reachable backend on a high-latency
// network still records the event.
const telemetryHTTPTimeout = 3 * time.Second

// telemetryFlushTimeout bounds how long flushTelemetry waits for
// in-flight goroutines on shutdown before giving up. Two seconds is
// enough headroom for one or two events to settle on a normal
// network without making the CLI exit feel sluggish.
const telemetryFlushTimeout = 2 * time.Second

// telemetryEnvDoNotTrack / telemetryEnvDisable are the two opt-out
// env vars the user can set. Pulled into constants so the doc and
// the code reference the exact same strings.
const (
	telemetryEnvDoNotTrack = "DO_NOT_TRACK"
	telemetryEnvDisable    = "DISABLE_TELEMETRY"
	telemetryEnvEndpoint   = "X_X_TELEMETRY_ENDPOINT"
)

// telemetryClient is the shared HTTP client. Single client per process
// so connection-keepalive can amortize TLS handshakes across multiple
// events in the same run.
var telemetryClient = &http.Client{Timeout: telemetryHTTPTimeout}

// telemetryWG tracks every in-flight ping so flushTelemetry can wait
// for them before the process exits. Each successful track() call
// Adds(1) before spawning its goroutine; the goroutine Done()s once
// the HTTP request returns (or times out).
var telemetryWG sync.WaitGroup

// telemetrySessionID is a per-process random hex string set once at
// package init. Lets the backend group events emitted by one CLI
// invocation (e.g. `x-x init` firing both `init` and a downstream
// `update_apply`) without enabling cross-session tracking — a fresh
// process always gets a fresh id.
var telemetrySessionID = newTelemetrySessionID()

// telemetryEvent is the param bag for one ping. Always carries an
// "event" key (e.g. "init") plus event-specific params; standard
// params (v, ci, os, arch, session_id) are merged in by track().
//
// Values are plain strings so the HTTP layer never has to introspect
// the type — every event marshals identically to a query string.
type telemetryEvent map[string]string

// track fires one telemetry event. Non-blocking: spawns a goroutine
// for the HTTP request and returns immediately. Silent on every
// failure mode (disabled by env, network down, non-2xx response) so
// the caller never has to handle a telemetry error.
//
// The "event" name is the leading positional arg so call sites read
// as `track("init", telemetryEvent{...})` rather than burying the
// event name inside the map.
func track(event string, params telemetryEvent) {
	if !telemetryEnabled() {
		return
	}
	q := url.Values{}
	q.Set("event", event)
	q.Set("v", Version)
	q.Set("os", runtime.GOOS)
	q.Set("arch", runtime.GOARCH)
	q.Set("session_id", telemetrySessionID)
	if telemetryIsCI() {
		q.Set("ci", "1")
	}
	for k, v := range params {
		// Don't let event-specific params clobber the standard ones —
		// the standard set is the floor every event must carry.
		if _, reserved := reservedTelemetryKeys[k]; reserved {
			continue
		}
		q.Set(k, v)
	}

	endpoint := telemetryEndpoint()
	telemetryWG.Add(1)
	go func() {
		defer telemetryWG.Done()
		// Build the request with an explicit context tied to the
		// per-request timeout — http.Client.Timeout alone would let
		// a slow body read leak past flushTelemetry's deadline.
		ctx, cancel := context.WithTimeout(context.Background(), telemetryHTTPTimeout)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"?"+q.Encode(), nil)
		if err != nil {
			return
		}
		resp, err := telemetryClient.Do(req)
		if err != nil {
			return
		}
		// Drain + close so the connection can be reused. Response body
		// is discarded — the backend's response is intentionally empty.
		_ = resp.Body.Close()
	}()
}

// reservedTelemetryKeys is the set of param names track() owns and
// will refuse to overwrite from caller-supplied params. Keeps the
// standard floor intact — a caller that passes `os: "??"` doesn't
// poison the OS attribution for that event.
var reservedTelemetryKeys = map[string]struct{}{
	"event":      {},
	"v":          {},
	"os":         {},
	"arch":       {},
	"session_id": {},
	"ci":         {},
}

// flushTelemetry blocks until every in-flight ping returns or the
// flush timeout fires, whichever comes first. Called by command
// handlers after their last track() call so the caller's normal
// return doesn't drop pending events. Subcommands that exit via
// os.Exit (e.g. exitErr) intentionally skip the flush — a fatal
// error path that lost telemetry is an acceptable trade for not
// adding a panic-recovery shim on every os.Exit call site.
func flushTelemetry() {
	done := make(chan struct{})
	go func() {
		telemetryWG.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(telemetryFlushTimeout):
	}
}

// telemetryEnabled reports whether telemetry should run for this
// process. Returns false if EITHER opt-out env var is set to a
// non-empty value. The check is recomputed on every call so a test
// that toggles the env var sees the change immediately.
func telemetryEnabled() bool {
	if os.Getenv(telemetryEnvDoNotTrack) != "" {
		return false
	}
	if os.Getenv(telemetryEnvDisable) != "" {
		return false
	}
	return true
}

// telemetryEndpoint returns the URL to ping. Honors
// X_X_TELEMETRY_ENDPOINT for test overrides; falls back to the
// production URL otherwise.
func telemetryEndpoint() string {
	if v := os.Getenv(telemetryEnvEndpoint); v != "" {
		return v
	}
	return telemetryURL
}

// telemetryIsCI reports whether the process appears to be running in
// CI. Mirrors the well-known env vars the Vercel reference checks,
// plus a couple of extras common in the runners the project targets
// (the bash + ps1 e2e harnesses set CI=true). Detection is best-
// effort — a CI runner that exports none of these is reported as
// non-CI.
func telemetryIsCI() bool {
	for _, k := range []string{
		"CI",
		"GITHUB_ACTIONS",
		"GITLAB_CI",
		"CIRCLECI",
		"TRAVIS",
		"BUILDKITE",
		"JENKINS_URL",
		"TEAMCITY_VERSION",
	} {
		if os.Getenv(k) != "" {
			return true
		}
	}
	return false
}

// newTelemetrySessionID generates a fresh random hex id for this
// process. 16 bytes → 32 hex chars, enough collision resistance
// across the project's expected install base without bloating the
// query string. Falls back to a timestamp-based fallback if the
// system RNG is unavailable so we never lose a session id.
func newTelemetrySessionID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		// crypto/rand.Read failing is exotic (FIPS init error, no
		// /dev/urandom on a stripped container). Use the start time
		// as a non-cryptographic fallback so events still carry
		// SOME correlation id. The leading "t" tag lets the backend
		// distinguish fallback ids from real random ones.
		return "t" + time.Now().UTC().Format("20060102T150405.000000000")
	}
	return hex.EncodeToString(buf)
}
