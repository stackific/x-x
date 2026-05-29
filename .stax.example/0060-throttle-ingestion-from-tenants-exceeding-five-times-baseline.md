---
title: Throttle ingestion from tenants exceeding five times baseline
status: valid
systems: [ingest-pipeline]
created: 2025-12-24T23:46:43Z
---

## Goal
Prevent a single noisy tenant from starving the rest of the platform by throttling tenants whose traffic exceeds five times their rolling baseline.

## Approach
- Compute per-tenant rolling baselines.
- Throttle by ratio.

## Tasks
- [x] If a tenant's event rate exceeds five times its rolling baseline, then the Ingest Pipeline shall throttle the tenant's consumption.
