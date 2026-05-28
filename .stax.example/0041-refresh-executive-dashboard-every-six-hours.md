---
title: Refresh executive dashboard every six hours
status: valid
systems: [analytics-warehouse]
created: 2025-10-10T23:31:07Z
---

## Goal
Speed up executive dashboards by refreshing their backing aggregates every six hours instead of nightly.

## Approach
- Add a six-hour cron for exec aggregates.
- Keep the nightly job as fallback.

## Tasks
- [x] When six hours have elapsed since the last refresh, the Analytics Warehouse shall recompute executive aggregates.
- [x] If a six-hour refresh fails, then the Analytics Warehouse shall fall back to the prior aggregate without raising an error to dashboards.
