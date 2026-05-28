---
title: Add quarterly board metrics rollup table
status: valid
systems: [analytics-warehouse]
created: 2025-11-06T11:53:53Z
---

## Goal
Roll up the board-relevant metrics into a single quarterly table so the board deck pulls from one source.

## Approach
- Aggregate ARR, NRR, churn, and CAC quarterly.
- Pin schema until next board cycle.

## Tasks
- [x] When a calendar quarter closes, the Analytics Warehouse shall compute the board metrics rollup.
