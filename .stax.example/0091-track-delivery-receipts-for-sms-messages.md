---
title: Track delivery receipts for SMS messages
status: valid
systems: [notification-bus]
created: 2026-05-07T17:20:35Z
---

## Goal
Record delivery, failure, and read receipts per SMS so customer support can confirm whether a message reached the user.

## Approach
- Wire provider receipt webhooks.
- Persist receipts per message id.

## Tasks
- [x] When the SMS provider returns a delivery receipt, the Notification Bus shall record it against the message id.
