---
title: Add delivery status webhook for sender side observability
status: valid
systems: [notification-bus]
created: 2026-05-26T10:11:15Z
---

## Goal
Let internal producers subscribe to a status webhook so they can observe delivery outcomes for their messages.

## Approach
- Emit status events per message terminal state.
- Sign each event with HMAC.

## Tasks
- [ ] When a message reaches a terminal delivery state, the Notification Bus shall emit a status webhook to the producer's subscription.
