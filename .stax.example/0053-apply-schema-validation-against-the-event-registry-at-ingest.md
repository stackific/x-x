---
title: Apply schema validation against the event registry at ingest
status: valid
systems: [ingest-pipeline]
extended_by: [0054-quarantine-malformed-events-into-a-dead-letter-topic]
created: 2026-01-08T20:40:00Z
---

## Goal
Reject events whose payload shape doesn't match the registered schema before they reach the bronze layer.

## Approach
- Look up the schema by event-type on each message.
- Validate; mark pass/fail.

## Tasks
- [x] When an event arrives, the Ingest Pipeline shall validate its payload against the registered schema.
- [x] If validation fails, the Ingest Pipeline shall mark the event as malformed.
