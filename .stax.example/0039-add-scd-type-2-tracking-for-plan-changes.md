---
title: Add SCD Type 2 tracking for plan changes
status: valid
systems: [analytics-warehouse]
created: 2025-10-09T20:50:00Z
---

## Goal
Track every plan change on a subscription as an SCD Type 2 row so historical analysis reflects the plan in effect at any past date.

## Approach
- Add valid_from and valid_to to dim_subscription.
- Close the prior row when a change arrives.

## Tasks
- [x] When a plan change arrives, the Analytics Warehouse shall close the current dim_subscription row.
- [x] When a plan change arrives, the Analytics Warehouse shall open a new dim_subscription row with valid_from set to the change time.
