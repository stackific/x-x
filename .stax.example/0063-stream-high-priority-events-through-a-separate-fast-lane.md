---
title: Stream high priority events through a separate fast lane
status: valid
systems: [ingest-pipeline]
created: 2026-01-14T07:38:31Z
---

## Goal
Route events tagged high-priority through a dedicated low-latency lane so they bypass the bulk queue.

## Approach
- Add a priority-aware router.
- Provision a dedicated consumer group.

## Tasks
- [x] When an event is tagged high-priority, the Ingest Pipeline shall route it to the fast lane.
