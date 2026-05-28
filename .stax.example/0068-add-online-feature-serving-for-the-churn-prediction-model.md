---
title: Add online feature serving for the churn prediction model
status: valid
systems: [feature-store]
extended_by: [0077-add-feature-drift-detection-for-live-serving]
created: 2026-01-27T08:07:00Z
---

## Goal
Expose an online feature vector lookup endpoint that the churn prediction model can call at inference time.

## Approach
- Materialise the churn feature view online.
- Cap p99 latency at 50ms.

## Tasks
- [x] When a model service requests a churn feature vector, the Feature Store shall return the latest vector for the entity.
- [x] If a feature vector is older than its declared freshness window, then the Feature Store shall return stale_data.
