---
title: Add quiet hours per recipient based on timezone
status: valid
systems: [notification-bus]
created: 2026-05-04T16:17:24Z
---

## Goal
Suppress non-critical notifications during a recipient's configured quiet hours, releasing them at the next allowed time.

## Approach
- Store quiet hours per recipient.
- Buffer suppressed messages.

## Tasks
- [x] While a recipient is inside quiet hours, the Notification Bus shall buffer non-critical messages.
- [x] When quiet hours end, the Notification Bus shall release buffered messages in arrival order.
