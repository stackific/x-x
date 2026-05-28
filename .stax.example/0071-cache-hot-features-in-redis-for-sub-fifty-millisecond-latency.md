---
title: Cache hot features in Redis for sub fifty millisecond latency
status: valid
systems: [feature-store]
created: 2026-02-16T01:31:59Z
---

## Goal
Cache the hottest features in Redis so the online endpoint responds within fifty milliseconds at p99.

## Approach
- Add a Redis fronting layer.
- Invalidate on feature update.

## Tasks
- [x] When a feature is updated, the Feature Store shall invalidate its Redis cache entry.
- [x] While a feature is cached, the Feature Store shall return the cached value without a database round trip.
