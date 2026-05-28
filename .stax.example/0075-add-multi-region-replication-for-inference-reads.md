---
title: Add multi region replication for inference reads
status: valid
systems: [feature-store]
created: 2026-03-01T23:24:08Z
---

## Goal
Replicate the online store to a second region so inference reads stay local and survive a region outage.

## Approach
- Replicate online vectors across regions.
- Route inference reads to the nearest region.

## Tasks
- [x] When an online vector is written, the Feature Store shall replicate it to the second region.
- [x] If the primary region is unreachable, then the Feature Store shall serve reads from the secondary region.
