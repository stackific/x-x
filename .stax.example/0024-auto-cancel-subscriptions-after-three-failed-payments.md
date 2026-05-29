---
title: Auto cancel subscriptions after three failed payments
status: valid
systems: [billing]
created: 2025-08-27T20:19:43Z
---

## Goal
Stop chasing customers whose card has been declined three times in a row by cancelling the subscription and notifying them.

## Approach
- Track consecutive failed payments per subscription.
- Cancel on the third failure.

## Tasks
- [x] When a subscription payment is declined, the Billing shall increment its consecutive-failure counter.
- [x] If a subscription has three consecutive failed payments, then the Billing shall cancel it.
- [x] When a payment succeeds, the Billing shall reset the consecutive-failure counter.
