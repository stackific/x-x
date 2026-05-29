---
title: Build product engagement scorecard refresh
status: valid
systems: [analytics-warehouse]
created: 2026-01-08T16:40:00Z
---

## Goal
Refresh the per-account engagement scorecard hourly so customer success sees activity changes within the same business hour.

## Approach
- Compute the scorecard from feature usage facts.
- Refresh hourly.

## Tasks
- [x] When an hour boundary passes, the Analytics Warehouse shall recompute the engagement scorecard.
