---
title: Add lineage from raw events to materialized features
status: valid
systems: [feature-store]
created: 2026-03-13T18:26:16Z
---

## Goal
Surface the lineage from raw events all the way to materialised features so ML engineers can trace a value back to its source.

## Approach
- Tag every feature with its upstream view.
- Publish lineage in the catalog.

## Tasks
- [x] When a feature is materialised, the Feature Store shall record its lineage from the upstream view.
