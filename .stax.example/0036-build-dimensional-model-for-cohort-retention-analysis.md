---
title: Build dimensional model for cohort retention analysis
status: valid
systems: [analytics-warehouse]
created: 2025-10-09T17:50:00Z
---

## Goal
Stand up a star schema that lets analysts run weekly cohort retention queries without writing one-off SQL.

## Approach
- Add fact_signup and dim_cohort tables.
- Refresh nightly with idempotent upserts.

## Tasks
- [x] When the nightly refresh runs, the Analytics Warehouse shall upsert fact_signup and dim_cohort.
- [x] When a cohort query runs against the model, the Analytics Warehouse shall return retention percentages by week.
