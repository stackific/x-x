---
title: Add configurable dedup window per channel
status: valid
systems: [notification-bus]
extends: [0090-suppress-duplicate-notifications-within-five-minutes]
created: 2026-05-27T04:55:44Z
---

## Goal
Make the 5-minute dedup window 0090 introduced configurable per channel, since SMS, email, and push each tolerate different repeat cadences.

## Approach
- Read the window from per-channel config.
- Default to 5 minutes when unset.

## Tasks
- [x] When a notification is queued, the Notification Bus shall apply the channel's configured dedup window.
- [x] If no per-channel window is configured, the Notification Bus shall fall back to the 5-minute default.
