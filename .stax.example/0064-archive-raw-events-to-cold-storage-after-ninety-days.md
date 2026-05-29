---
title: Archive raw events to cold storage after ninety days
status: valid
systems: [ingest-pipeline]
created: 2026-01-14T14:02:01Z
---

## Goal
Move raw event files older than ninety days to cold storage to reduce hot-storage cost while keeping them queryable on demand.

## Approach
- Tag files by age.
- Move ninety-day files to the cold tier.

## Tasks
- [x] When a raw event file is older than ninety days, the Ingest Pipeline shall move it to cold storage.
