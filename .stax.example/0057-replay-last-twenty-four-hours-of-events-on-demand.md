---
title: Replay last twenty four hours of events on demand
status: valid
systems: [ingest-pipeline]
created: 2026-01-09T00:40:00Z
---

## Goal
Expose an operator endpoint that replays the last twenty-four hours of events into the bronze layer.

## Approach
- Expose a replay endpoint protected by an operator role.
- Replay idempotently using event ids.

## Tasks
- [x] When an operator invokes the replay endpoint, the Ingest Pipeline shall replay events from the last twenty-four hours.
- [x] If a replayed event is already present in bronze, then the Ingest Pipeline shall skip it.
