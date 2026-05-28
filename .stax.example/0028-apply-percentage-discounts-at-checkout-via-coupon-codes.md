---
title: Apply percentage discounts at checkout via coupon codes
status: valid
systems: [billing]
created: 2025-09-06T16:06:29Z
---

## Goal
Honor a redeemable coupon code at checkout that applies a percentage discount to the first invoice or the lifetime of the subscription.

## Approach
- Validate the coupon at checkout.
- Persist the discount terms on the subscription.

## Tasks
- [x] When a valid coupon is applied at checkout, the Billing shall record the percentage discount on the subscription.
- [x] While a discount is active, the Billing shall reduce each invoice by the recorded percentage.
- [x] If a coupon code has expired, then the Billing shall reject the application.
