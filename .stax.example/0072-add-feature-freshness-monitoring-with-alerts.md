---
title: Add feature freshness monitoring with alerts
status: valid
systems: [feature-store]
created: 2026-02-21T00:49:03Z
---

## Goal
Alert the ML team when any registered feature has not been refreshed within its declared freshness window.

## Approach
- Track last-refresh timestamps per feature.
- Page when stale.

## Tasks
- [x] If a feature exceeds its freshness window, then the Feature Store shall page the ML on-call rotation.
