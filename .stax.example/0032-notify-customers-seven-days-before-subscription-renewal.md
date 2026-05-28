---
title: Notify customers seven days before subscription renewal
status: valid
systems: [billing, notification-bus]
created: 2025-09-11T17:15:45Z
---

## Goal
Give customers a one-week warning before a subscription auto-renews, including the renewal amount.

## Approach
- Schedule a renewal-warning job seven days ahead.
- Hand the message off to the notification bus.

## Tasks
- [x] When a subscription is seven days from renewal, the Billing shall enqueue a renewal warning.
- [x] When a renewal warning is enqueued, the Notification Bus shall deliver it via the customer's preferred channel.
