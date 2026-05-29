---
title: Promote validated features from staging to production
status: valid
systems: [feature-store]
created: 2026-02-21T02:58:58Z
---

## Goal
Add an explicit promotion step that copies a validated feature from staging to production with an immutable version tag.

## Approach
- Add a promote endpoint.
- Stamp the promoted version with a hash.

## Tasks
- [x] When a feature is promoted, the Feature Store shall stamp the production copy with an immutable version hash.
- [x] If a promotion is attempted on an unvalidated feature, then the Feature Store shall reject the request.
