---
title: Add point in time correctness checks for offline features
status: valid
systems: [feature-store]
created: 2026-01-31T16:03:03Z
---

## Goal
Guarantee that offline feature retrieval never returns a value newer than the training row's event timestamp.

## Approach
- Index features by event time.
- Validate at retrieval.

## Tasks
- [x] When an offline retrieval requests features as of an event time, the Feature Store shall return only values valid at that time.
- [x] If a retrieval requests features for a future event time, then the Feature Store shall reject the request.
