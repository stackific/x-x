---
title: Add typed feature schema with backwards compatibility
status: valid
systems: [feature-store]
created: 2026-02-27T19:52:23Z
---

## Goal
Enforce a typed schema for every feature with backwards-compatible evolution rules so a schema change cannot break existing consumers.

## Approach
- Register typed schemas per feature.
- Reject backwards-incompatible changes.

## Tasks
- [x] When a feature schema is registered, the Feature Store shall enforce the declared type on every write.
- [x] If a feature schema change is backwards-incompatible, then the Feature Store shall reject the change.
