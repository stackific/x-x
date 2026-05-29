---
title: Add idempotency keys to deduplicate retried events
status: valid
systems: [ingest-pipeline]
created: 2026-01-09T04:40:00Z
---

## Goal
Avoid double-processing replayed or retried events by deduplicating on a producer-supplied idempotency key.

## Approach
- Require the idempotency-key header.
- Cache seen keys for forty-eight hours.

## Tasks
- [x] When an event arrives without an idempotency key, the Ingest Pipeline shall reject it.
- [x] If a previously seen idempotency key arrives, then the Ingest Pipeline shall ignore the duplicate.
