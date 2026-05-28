---
title: Implement soft delete tombstones in fact tables
status: valid
systems: [analytics-warehouse]
created: 2025-11-06T17:23:36Z
---

## Goal
Track soft deletes in the source by adding deleted-at tombstones to fact tables, preserving historical truth without dropping rows.

## Approach
- Add deleted_at to fact tables.
- Default analyst views to non-deleted rows.

## Tasks
- [x] When a source row is soft-deleted, the Analytics Warehouse shall set deleted_at on the corresponding fact row.
- [x] While a fact row has deleted_at set, the Analytics Warehouse shall exclude it from default analyst views.
