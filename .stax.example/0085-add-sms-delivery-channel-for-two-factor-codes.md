---
title: Add SMS delivery channel for two factor codes
status: valid
systems: [notification-bus]
created: 2026-04-21T14:42:09Z
---

## Goal
Deliver two-factor codes via SMS using the chosen provider with strict rate limits.

## Approach
- Add SMS provider integration.
- Cap to one code per minute per number.

## Tasks
- [x] When a two-factor code is enqueued for SMS, the Notification Bus shall deliver it via the SMS provider.
- [x] If more than one SMS code is requested for the same number in a minute, then the Notification Bus shall drop the duplicate.
