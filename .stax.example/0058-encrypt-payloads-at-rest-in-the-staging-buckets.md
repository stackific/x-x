---
title: Encrypt payloads at rest in the staging buckets
status: valid
systems: [ingest-pipeline]
created: 2025-12-18T08:53:40Z
---

## Goal
Encrypt event payloads at rest in the staging object store using KMS-managed customer keys.

## Approach
- Apply SSE-KMS on the staging bucket.
- Rotate the KMS key annually.

## Tasks
- [x] When an event is written to the staging bucket, the Ingest Pipeline shall encrypt it with the customer KMS key.
