---
title: Backfill three years of historical signups
status: valid
systems: [analytics-warehouse]
created: 2025-10-09T19:50:00Z
---

## Goal
Hydrate the warehouse with three years of historical signup events from the source database so trend analysis is meaningful from day one.

## Approach
- Run a one-shot backfill in monthly partitions.
- Verify counts against the source.

## Tasks
- [x] When the backfill runs, the Analytics Warehouse shall ingest signup events for every month in the three-year window.
- [x] If a monthly partition count does not match the source, then the Analytics Warehouse shall halt the backfill and surface the mismatch.
