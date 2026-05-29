---
title: Add notification preference center for end users
status: valid
systems: [notification-bus]
created: 2026-05-15T11:02:58Z
---

## Goal
Let users opt in or out of each notification category per channel from a dedicated preference center.

## Approach
- Add per-category opt-in flags.
- Honor them at fan-out time.

## Tasks
- [x] While a user has opted out of a category, the Notification Bus shall not deliver messages from that category to that user.
