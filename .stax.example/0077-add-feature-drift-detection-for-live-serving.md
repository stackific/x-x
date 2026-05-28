---
title: Add feature drift detection for live serving
status: valid
systems: [feature-store]
created: 2026-03-06T19:03:08Z
---

## Goal
Compare the live feature distribution against the training distribution and raise a drift alert when divergence exceeds a threshold.

## Approach
- Compute distribution snapshots hourly.
- Compare against the training baseline.

## Tasks
- [x] When the hourly drift job runs, the Feature Store shall compute a distribution snapshot per feature.
- [x] If a feature's KL divergence exceeds the configured threshold, then the Feature Store shall raise a drift alert.
