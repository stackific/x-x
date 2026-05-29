---
title: Apply per tenant rate limits to outbound notifications
status: valid
systems: [notification-bus]
created: 2026-05-11T00:09:05Z
---

## Goal
Cap each tenant's outbound notification rate so one misbehaving tenant cannot exhaust shared provider quotas.

## Approach
- Track a rolling counter per tenant.
- Drop or queue once the cap is hit.

## Tasks
- [x] If a tenant's outbound rate exceeds its configured cap, then the Notification Bus shall queue further messages.
