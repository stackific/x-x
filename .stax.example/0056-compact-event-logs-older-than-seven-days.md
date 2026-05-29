---
title: Compact event logs older than seven days
status: valid
systems: [ingest-pipeline]
created: 2026-01-08T23:40:00Z
---

## Goal
Reduce storage cost by compacting event logs older than seven days into per-day Parquet files.

## Approach
- Schedule a nightly compaction job.
- Drop the source files once compaction succeeds.

## Tasks
- [x] When the nightly compaction job runs, the Ingest Pipeline shall compact events older than seven days into daily Parquet files.
- [x] If compaction fails for a partition, then the Ingest Pipeline shall keep the source files in place.
