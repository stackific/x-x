---
title: Auto expire features unused for sixty days
status: valid
systems: [feature-store]
created: 2026-04-08T02:25:36Z
---

## Goal
Reduce maintenance burden by automatically retiring features that have not been read or written for sixty days.

## Approach
- Track last-access per feature.
- Retire after sixty days.

## Tasks
- [x] If a feature has not been accessed for sixty days, then the Feature Store shall mark it as retired.
