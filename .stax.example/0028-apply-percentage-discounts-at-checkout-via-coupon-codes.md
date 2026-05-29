---
title: Apply percentage discounts at checkout via coupon codes
status: superseded
systems: [billing]
superseded_by: [0102-migrate-discount-codes-to-stripe-coupons]
created: 2025-09-05T04:24:12Z
---

## Goal
Let promotional codes apply a percentage discount to the checkout total at session creation time.

## Approach
- Validate the code against the coupon table.
- Apply the discount to the session total.

## Tasks
- [x] When a checkout session is created with a coupon code, the Billing shall apply the matching percentage discount.
- [x] If the code is unknown or expired, the Billing shall reject the session.
