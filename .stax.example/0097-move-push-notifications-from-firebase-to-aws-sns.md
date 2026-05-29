---
title: Move push notifications from Firebase to AWS SNS
status: valid
systems: [notification-bus]
created: 2026-05-21T20:33:21Z
---

## Goal
Cut over mobile push notifications from Firebase Cloud Messaging to AWS SNS to consolidate on a single cloud provider.

## Approach
- Dual-write during cutover.
- Decommission Firebase once parity is confirmed.

## Tasks
- [ ] While dual-write is enabled, the Notification Bus shall deliver each push via both Firebase and SNS.
- [ ] When SNS becomes the source of truth, the Notification Bus shall stop sending via Firebase.
