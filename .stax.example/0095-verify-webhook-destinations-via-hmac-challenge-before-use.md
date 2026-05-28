---
title: Verify webhook destinations via HMAC challenge before use
status: valid
systems: [notification-bus]
created: 2026-05-17T09:02:44Z
---

## Goal
Confirm ownership of a webhook destination by requiring the customer to echo an HMAC challenge before deliveries begin.

## Approach
- Issue an HMAC challenge on add.
- Hold delivery until the challenge succeeds.

## Tasks
- [x] When a webhook destination is added, the Notification Bus shall issue an HMAC challenge.
- [x] If the challenge response is incorrect, then the Notification Bus shall keep the destination disabled.
