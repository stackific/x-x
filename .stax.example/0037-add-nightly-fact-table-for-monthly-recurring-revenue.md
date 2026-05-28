---
title: Add nightly fact table for monthly recurring revenue
status: valid
systems: [analytics-warehouse]
created: 2025-10-04T05:06:43Z
---

## Goal
Materialise an MRR fact table updated nightly so finance dashboards can break MRR down by plan, region, and acquisition channel.

## Approach
- Calculate MRR per subscription per day.
- Pivot in the BI layer.

## Tasks
- [x] When the nightly job runs, the Analytics Warehouse shall compute MRR for every active subscription.
- [x] When a finance dashboard queries MRR, the Analytics Warehouse shall return the latest fact row.
