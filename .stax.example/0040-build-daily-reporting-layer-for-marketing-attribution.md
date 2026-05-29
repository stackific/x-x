---
title: Build daily reporting layer for marketing attribution
status: valid
systems: [analytics-warehouse]
created: 2025-10-09T21:50:00Z
---

## Goal
Expose a curated reporting view that maps each signup to its first-touch and last-touch marketing channels.

## Approach
- Add fact_attribution joining clickstream to signups.
- Refresh daily.

## Tasks
- [x] When the daily refresh runs, the Analytics Warehouse shall update fact_attribution.
- [x] When a marketing dashboard queries attribution, the Analytics Warehouse shall return first-touch and last-touch channels per signup.
