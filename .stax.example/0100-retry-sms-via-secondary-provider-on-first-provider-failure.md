---
title: Retry SMS via secondary provider on first provider failure
status: valid
systems: [notification-bus]
created: 2026-05-27T00:55:44Z
---

## Goal
Fail over to a secondary SMS provider when the primary returns a hard failure, preserving deliverability during partial outages.

## Approach
- Configure primary and secondary providers.
- Fail over on hard errors only.

## Tasks
- [ ] When the primary SMS provider returns a hard failure, the Notification Bus shall retry the message via the secondary provider.
- [ ] If both providers return hard failures, then the Notification Bus shall move the message to the failed queue.
