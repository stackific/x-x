---
title: Add late arriving event reconciliation window
status: valid
systems: [ingest-pipeline]
created: 2026-01-24T13:55:42Z
---

## Goal
Accept events that arrive up to seventy-two hours late and reconcile them into the correct event-date partition.

## Approach
- Accept late events for seventy-two hours.
- Re-run downstream aggregates for the affected partitions.

## Tasks
- [x] When an event arrives more than one hour after its event date, the Ingest Pipeline shall route it to its event-date partition.
- [x] If a late event arrives more than seventy-two hours after its event date, then the Ingest Pipeline shall reject it.
