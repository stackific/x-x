# Anonymous-usage telemetry

This document is the contract between the `x-x` CLI (the producer) and the future Stackific telemetry endpoint at `https://stackific.com/x-x/t` (the consumer). It exists so the backend team can implement the receiver against a fixed wire format without having to read Go source, and so any future event added to the CLI lands in an already-documented place.

> **Status:** The CLI fires the `init` event today. The endpoint is not yet implemented; pings 404 silently in production. The CLI swallows every error so this is invisible to users.

## Endpoint

| | |
|---|---|
| URL | `https://stackific.com/x-x/t` |
| Method | `GET` |
| Body | none — every param is in the query string |
| Expected response | `204 No Content` (any 2xx is treated as success; non-2xx and timeouts are silently ignored) |
| Per-request timeout | 3 seconds (`telemetryHTTPTimeout` in `telemetry.go`) |
| Process-exit flush deadline | 2 seconds (`telemetryFlushTimeout`) |

The receiver must treat the endpoint as idempotent — clients fire events from goroutines and may retry on transient network failure in a future revision. The receiver should never block on database writes or external lookups; queue + ack quickly.

## Opt-out

Telemetry is **on by default**. Two env vars disable it; either one being set to a non-empty value is sufficient:

| Env var | Source | Notes |
|---|---|---|
| `DO_NOT_TRACK` | [consoledonottrack.com](https://consoledonottrack.com/) | Industry-standard. Honor it. |
| `DISABLE_TELEMETRY` | Project-specific | Belt-and-braces escape hatch for users who want to flip x-x off without affecting other tools. |

There is **no first-run consent banner** today. Both opt-out vars are documented in `docs/public/reference.md`. The `scripts/e2e_test.sh` + `scripts/e2e_test.ps1` harnesses set both at the top so CI test traffic never reaches the production endpoint.

## Standard params

Every event carries these. They are merged in by `track()`; an event-specific param with the same name is dropped (the standard floor is non-overrideable).

| Param | Source | Example |
|---|---|---|
| `event` | First positional arg to `track()` | `init` |
| `v` | The `Version` package var (release: `v0.1.2`; local: `dev`) | `v0.1.2` |
| `os` | `runtime.GOOS` | `linux` / `darwin` / `windows` |
| `arch` | `runtime.GOARCH` | `amd64` / `arm64` |
| `session_id` | Per-process random 16-byte hex (`crypto/rand`) | `4f3c1a2e9b1d7e5f1c2b8a4d6f0e9c1d` |
| `ci` | Set to `1` if any of: `CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `CIRCLECI`, `TRAVIS`, `BUILDKITE`, `JENKINS_URL`, `TEAMCITY_VERSION` is non-empty. Omitted otherwise. | `1` |

`session_id` is **per-process only** — a deliberate non-feature. The CLI does NOT persist a machine id, so the backend cannot correlate events across separate invocations or across users. This caps what cross-event analysis the backend can perform; that's the privacy trade.

## Event catalog

Each row shows the event name, what CLI action fires it, and the event-specific params on top of the standard floor. Wired column: ✅ = call site exists in the CLI today, ⏳ = reserved name, no call site yet (add when the matching feature ships).

| Event | Fired by | Event-specific params | Wired |
|---|---|---|---|
| `init` | End of `runInit` happy path (`init.go`) | `scope` (`project`/`user`), `agents` (comma-joined keys), `agent_count`, `skill_count` | ✅ |
| `skills_remove` | End of `runSkillsRemove` happy path (`skill.go`) | `scope`, `agent_count`, `skill_count_removed`, `hook_count_unmerged` | ⏳ |
| `plans_lint` | End of `planLint` | `plan_count`, `fail_count`, `duration_ms` | ⏳ |
| `plans_next_prefix` | End of `planNextPrefix` | `prefix` | ⏳ |
| `plans_slugify` | End of `planSlugify` | `input_chars`, `output_chars` | ⏳ |
| `update_check` | `maybeNotifyUpdate` after a successful GitHub round-trip | `from_version`, `to_version`, `has_update` (`1`/`0`) | ⏳ |
| `update_apply` | `writeBundledAgents(true)` after rewriting `~/.x-x/agents/` | `from_version`, `to_version`, `success_count`, `fail_count` | ⏳ |
| `command_failed` | Wrapping every subcommand's non-zero exit | `command`, `exit_code` | ⏳ |
| `find` | Reserved for a future search subcommand | `query_chars`, `result_count`, `interactive` (`1`/`0`) | ⏳ |
| `audit` | Reserved for a future skill-source security lookup | `source`, `skill_count`, `risk` | ⏳ |

### Adding a new event

1. Pick a snake_case name. Check the table above for collisions.
2. Add a row to the table above with the param list.
3. In the CLI, call `track("<name>", telemetryEvent{...})` at the end of the happy path for the relevant action, then `flushTelemetry()` before normal return.
4. Add a unit test in `telemetry_test.go` that asserts the event fires with the expected params (use `pointTelemetryAt(t, httptest.URL)` to intercept).
5. Update this doc's "Wired" column from ⏳ to ✅.

## What is NEVER sent

The receiver must be able to audit the producer for these guarantees by inspecting the CLI source:

- **No file contents.** No plan file body, no SKILL.md body, no settings.json body, no source code.
- **No absolute paths.** Param values are bounded enumerations (`project`/`user`), comma-joined registry keys (`claude,codex`), or small integers. No `/Users/...`, no `/home/...`, no `C:\Users\...`.
- **No project identifiers.** No git remote URL, no working-directory path, no commit hash, no branch name.
- **No agent CLI output.** No content the underlying agent (Claude / Codex / etc.) emitted.
- **No machine identifiers.** No hostname, no MAC, no disk UUID, no persistent install id. `session_id` is randomized per process.
- **No env-var values.** The `ci` flag is the only env-derived signal; we report its presence as a boolean, never the value.
- **No skill content.** Skill names are bundled, not user-supplied, and only enumerated as keys.

If a future event would violate any of these, the doc must call out the new payload explicitly and the PR adding it must justify the change.

## Backend implementation expectations

A minimal compliant receiver:

1. Accepts `GET /t?event=<name>&...`. Returns `204 No Content` regardless of whether the event was recognized or queued.
2. Logs every request's query string + receive timestamp to whatever backing store the team chooses (Vercel KV, BigQuery, Postgres, etc.).
3. Does **not** log the client IP or any header value beyond what's needed for abuse-prevention. The IP is incidental to a server log; do not promote it to a queryable column.
4. Rate-limits per source IP at a sensible threshold (suggest 60 RPS / IP) to absorb a buggy client without bringing the endpoint down.
5. Is reachable over HTTP/2 with valid TLS — the CLI's `net/http` default client requires it.

The producer's HTTP client uses Go's default User-Agent (`Go-http-client/2.0`) — the team may want to wire a dedicated agent header in a follow-up if log analytics needs to distinguish `x-x` from other Go clients sharing the platform.

## Testing the producer

The endpoint is overridable via `X_X_TELEMETRY_ENDPOINT` (string, full URL including scheme). Unit tests in `telemetry_test.go` stand up an `httptest.Server`, point the CLI at it via `pointTelemetryAt(t, srv.URL)`, fire `track(...)`, and assert on the recorded request's `url.Values`. The end-to-end test harnesses (`scripts/e2e_test.sh`, `scripts/e2e_test.ps1`) export both opt-out env vars at the top, so the production endpoint is never reached from any test path.

A future "telemetry e2e" — pointing the CLI at a local capture server and exercising a real `x-x init` — is worth adding once the backend exists and we want to validate the wire format against a non-mock receiver.
