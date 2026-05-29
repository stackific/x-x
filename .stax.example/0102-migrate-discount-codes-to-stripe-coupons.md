---
title: Migrate discount codes to Stripe coupons
status: valid
systems: [billing]
supersedes: [0028-apply-percentage-discounts-at-checkout-via-coupon-codes]
created: 2026-05-12T14:20:00Z
---

## Goal
Move discount application from our bespoke coupon table to Stripe Coupons so promotional codes work with Stripe Checkout out of the box.

## Approach
- Mirror existing codes to Stripe.
- Apply Stripe coupons at checkout session creation.

## Tasks
- [x] When a checkout session is created with a coupon code, the Billing shall attach the matching Stripe coupon to the session.
- [x] If the supplied code has no Stripe coupon, the Billing shall reject the session with an unknown_coupon error.
