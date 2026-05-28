---
title: Throttle email notifications to one per recipient per hour
status: superseded
systems: [notification-bus]
superseded_by: [0089-add-quiet-hours-per-recipient-based-on-timezone]
created: 2026-04-25T14:56:15Z
---

## Goal
Avoid noisy inboxes by throttling non-critical email notifications to at most one per recipient per hour.

## Approach
- Apply a per-recipient sliding window.
- Mark critical messages as exempt.

## Tasks
- [x] While a recipient has received an email in the past hour, the Notification Bus shall coalesce further non-critical messages.
