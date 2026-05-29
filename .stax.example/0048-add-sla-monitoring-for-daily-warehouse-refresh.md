---
title: Add SLA monitoring for daily warehouse refresh
status: valid
systems: [analytics-warehouse]
created: 2026-01-08T15:40:00Z
---

## Goal
Page on-call when the daily warehouse refresh has not completed by 06:00 UTC so dashboards do not silently show stale data.

## Approach
- Track refresh start and end timestamps.
- Page if no success by 06:00 UTC.

## Tasks
- [x] If the daily refresh has not completed by 06:00 UTC, then the Analytics Warehouse shall page the on-call rotation.
