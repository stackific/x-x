---
title: Add canary feature deployment workflow
status: valid
systems: [feature-store]
extended_by: [0105-add-feature-store-canary-rollback-watcher]
created: 2026-04-18T09:30:00Z
---

## Goal
Roll new features out to a small slice of traffic before the full population so regressions are caught early.

## Approach
- Route a configurable percentage to the new version.
- Compare its metrics against the baseline.

## Tasks
- [x] When a feature canary starts, the Feature Store shall route the configured percentage of inference reads to the canary version.
- [x] When the canary completes, the Feature Store shall promote the canary version to the default route.
