---
title: Backfill one hundred eighty days of feature vectors
status: valid
systems: [feature-store]
created: 2026-01-27T17:31:23Z
---

## Goal
Hydrate the offline store with one hundred eighty days of feature vectors so model retraining can compare against historical inputs.

## Approach
- Run the backfill in seven-day chunks.
- Validate counts per feature.

## Tasks
- [x] When the backfill runs, the Feature Store shall materialise feature vectors for every entity over the past one hundred eighty days.
