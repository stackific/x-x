---
title: Cache hot features in Redis for sub fifty millisecond latency
status: valid
systems: [feature-store]
extends: [0068-add-online-feature-serving-for-the-churn-prediction-model]
created: 2026-02-12T09:45:00Z
---

## Goal
Layer a Redis cache in front of the online serving endpoint 0068 added so p99 latency on hot keys stays under 50ms.

## Approach
- Cache by entity-id with a short TTL.
- Fall back to the primary store on miss.

## Tasks
- [x] When a feature vector is requested, the Feature Store shall return the cached entry if it exists.
- [x] If the cache misses, the Feature Store shall fetch from the primary store and populate the cache.
