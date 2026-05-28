---
title: Add column level data lineage documentation
status: valid
systems: [analytics-warehouse]
created: 2025-10-22T05:16:03Z
---

## Goal
Surface column-level lineage for every modelled column so analysts can trace a metric back to its source events.

## Approach
- Adopt the data-lineage tool's column tagging.
- Publish the lineage graph in the catalog.

## Tasks
- [x] When a model is published, the Analytics Warehouse shall record column-level lineage to its source events.
