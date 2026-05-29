---
title: Add quiet hours per recipient based on timezone
status: valid
systems: [notification-bus]
supersedes: [0086-throttle-email-notifications-to-one-per-recipient-per-hour]
created: 2026-05-04T16:17:24Z
---

## Goal
Suppress non-critical notifications during a recipient's configured quiet hours, releasing them at the next allowed time. Replaces the older per-hour throttle with a timezone-aware schedule each recipient controls.

## Approach
- Store quiet hours per recipient.
- Buffer suppressed messages.
- Honour the recipient's IANA timezone on every quiet-hours decision.

## Tasks
- [x] While a recipient is inside quiet hours, the Notification Bus shall buffer non-critical messages.
- [x] When quiet hours end, the Notification Bus shall release buffered messages in arrival order.
- [x] When a recipient updates their quiet-hours schedule, the Notification Bus shall apply the new window on the next decision.
