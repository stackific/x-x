---
title: Add canary feature deployment workflow
status: valid
systems: [feature-store]
created: 2026-04-04T20:35:35Z
---

## Goal
Route a small percentage of inference reads to a canary version of a feature before promoting it to all callers.

## Approach
- Assign canary weight per feature.
- Compare distributions before promotion.

## Tasks
- [x] While a canary weight is configured, the Feature Store shall route the configured percentage of reads to the canary version.
