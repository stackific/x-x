---
title: Suppress duplicate notifications within five minutes
status: valid
systems: [notification-bus]
extended_by: [0104-add-configurable-dedup-window-per-channel]
created: 2026-05-01T16:00:00Z
---

## Goal
Stop firing the same notification twice within a 5-minute window so a flapping upstream doesn't spam recipients.

## Approach
- Hash (recipient, payload).
- Suppress if seen in the last 5 minutes.

## Tasks
- [x] When a notification is queued, the Notification Bus shall suppress it if the same recipient saw the same payload in the last 5 minutes.
- [x] When 5 minutes pass since the last delivery, the Notification Bus shall release the suppression for that pair.
