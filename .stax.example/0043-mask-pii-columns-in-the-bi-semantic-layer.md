---
title: Mask PII columns in the BI semantic layer
status: superseded
systems: [analytics-warehouse]
superseded_by: [0103-move-pii-masking-from-bi-layer-to-warehouse-views]
created: 2026-01-08T10:40:00Z
---

## Goal
Mask PII columns at the BI semantic layer so dashboards never expose raw values.

## Approach
- Wrap sensitive columns in a mask function in the semantic model.
- Grant unmask only to specific roles.

## Tasks
- [x] When a dashboard queries a sensitive column, the Analytics Warehouse shall return the masked value.
- [x] If the caller holds the unmask role, the Analytics Warehouse shall return the raw value.
