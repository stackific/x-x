---
title: Quarantine malformed events into a dead-letter topic
status: valid
systems: [ingest-pipeline]
extends: [0053-apply-schema-validation-against-the-event-registry-at-ingest]
created: 2026-01-08T21:40:00Z
---

## Goal
Send the malformed events 0053 detects to a dedicated dead-letter topic so on-call can inspect them without blocking the main pipeline.

## Approach
- Route messages marked malformed to a DLQ topic.
- Keep them for 14 days.

## Tasks
- [x] When the Ingest Pipeline marks an event malformed, the Ingest Pipeline shall publish it to the dead-letter topic.
- [x] When a DLQ message ages past 14 days, the Ingest Pipeline shall drop it.
