---
title: Add CI checks for feature schema changes
status: valid
systems: [feature-store]
created: 2026-04-11T11:16:43Z
---

## Goal
Run a CI check on every pull request that touches a feature schema, blocking backwards-incompatible changes from merging.

## Approach
- Add a schema-diff job to CI.
- Block merge on incompatible diff.

## Tasks
- [x] When a pull request changes a feature schema, the Feature Store shall run a schema-compatibility check.
- [x] If the check finds a backwards-incompatible change, then the Feature Store shall block the pull request from merging.
