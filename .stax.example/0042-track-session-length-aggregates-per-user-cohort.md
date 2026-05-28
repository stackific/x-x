---
title: Track session length aggregates per user cohort
status: valid
systems: [analytics-warehouse]
created: 2025-10-13T08:45:31Z
---

## Goal
Aggregate session length percentiles per cohort to support product analytics on engagement depth.

## Approach
- Add fact_session_length keyed by cohort and date.
- Compute p50, p90, p99 daily.

## Tasks
- [x] When the daily session aggregator runs, the Analytics Warehouse shall compute p50, p90, and p99 session length per cohort.
