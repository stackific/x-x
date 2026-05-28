---
title: Add schema evolution alerts when payload shape changes
status: valid
systems: [ingest-pipeline]
created: 2026-01-24T07:48:14Z
---

## Goal
Notify the data team whenever an event's payload introduces a new field or changes an existing type at ingest.

## Approach
- Diff against the registered schema.
- Notify on additive or breaking changes.

## Tasks
- [x] When a payload introduces a field not in the registered schema, the Ingest Pipeline shall raise a schema-evolution alert.
