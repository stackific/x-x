---
title: Forward PII fields through a tokenization service
status: valid
systems: [ingest-pipeline]
created: 2026-01-26T08:02:41Z
---

## Goal
Replace PII fields with deterministic tokens at ingest so downstream stores never hold raw PII.

## Approach
- Call the tokenization service per PII field.
- Persist only the token.

## Tasks
- [x] When an event contains a PII field, the Ingest Pipeline shall replace the field with the token returned by the tokenization service.
- [x] If the tokenization service is unavailable, then the Ingest Pipeline shall pause ingestion until it recovers.
