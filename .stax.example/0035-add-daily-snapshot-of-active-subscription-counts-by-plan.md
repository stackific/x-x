---
title: Add daily snapshot of active subscription counts by plan
status: valid
systems: [analytics-warehouse]
created: 2025-09-25T20:03:05Z
---

## Goal
Materialise a daily snapshot of how many active subscriptions exist per plan so executives can chart the trend.

## Approach
- Run a nightly job that counts active subscriptions.
- Insert a dated row per plan.

## Tasks
- [x] When the nightly snapshot job runs, the Analytics Warehouse shall record active subscription counts per plan.
- [x] If the snapshot job fails, then the Analytics Warehouse shall raise an alert before noon UTC.
