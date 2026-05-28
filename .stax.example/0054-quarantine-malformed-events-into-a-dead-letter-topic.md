---
title: Quarantine malformed events into a dead letter topic
status: valid
systems: [ingest-pipeline]
created: 2025-12-02T08:45:22Z
---

## Goal
Capture every malformed event for replay and forensics by writing it to a dedicated dead-letter topic with the original headers.

## Approach
- Preserve original headers and payload bytes.
- Surface the dead-letter topic in the ingest dashboard.

## Tasks
- [x] When the Ingest Pipeline rejects an event, the Ingest Pipeline shall write it to the dead-letter topic with original headers preserved.
