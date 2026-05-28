---
title: Add row level access control to sensitive features
status: valid
systems: [feature-store]
created: 2026-04-01T20:42:35Z
---

## Goal
Restrict access to sensitive features by team and project so unrelated models cannot read them.

## Approach
- Tag features with sensitivity labels.
- Apply per-team allowlists.

## Tasks
- [x] While a caller lacks the required team allowlist, the Feature Store shall deny reads on sensitive features.
- [x] If a denied read is attempted, then the Feature Store shall log an audit event.
