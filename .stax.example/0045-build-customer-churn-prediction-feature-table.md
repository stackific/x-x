---
title: Build customer churn prediction feature table
status: valid
systems: [analytics-warehouse, feature-store]
created: 2026-01-08T12:40:00Z
---

## Goal
Materialise the feature table that backs the churn prediction model and sync it to the feature store nightly.

## Approach
- Compute features in the warehouse.
- Sync to the feature store on a nightly job.

## Tasks
- [x] When the nightly churn job runs, the Analytics Warehouse shall recompute the churn feature table.
- [x] When the churn feature table is recomputed, the Feature Store shall sync the new vectors.
