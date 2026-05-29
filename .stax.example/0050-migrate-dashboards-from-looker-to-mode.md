---
title: Migrate dashboards from Looker to Mode
status: valid
systems: [analytics-warehouse]
created: 2026-01-08T17:40:00Z
---

## Goal
Cut over the company dashboards from Looker to Mode, keeping query semantics consistent through the semantic layer.

## Approach
- Port LookML to Mode definitions.
- Retire Looker once parity is confirmed.

## Tasks
- [x] When a dashboard is migrated, the Analytics Warehouse shall serve identical results to the Looker version.
- [x] If a Mode dashboard diverges from its Looker counterpart, then the Analytics Warehouse shall block the migration until reconciled.
