---
title: Apply schema validation against the event registry at ingest
status: valid
systems: [ingest-pipeline]
created: 2025-11-27T18:42:53Z
---

## Goal
Reject malformed events at the ingest boundary by validating against the registered schema before they reach the warehouse.

## Approach
- Fetch schemas from the registry per topic.
- Reject mismatches into a dead-letter topic.

## Tasks
- [x] When an event arrives, the Ingest Pipeline shall validate it against the registered schema.
- [x] If an event fails schema validation, then the Ingest Pipeline shall write it to the dead-letter topic.
