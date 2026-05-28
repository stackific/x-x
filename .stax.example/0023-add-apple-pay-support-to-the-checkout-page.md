---
title: Add Apple Pay support to the checkout page
status: deprecated
systems: [billing]
created: 2025-08-22T11:00:58Z
---

## Goal
Let customers complete checkout using Apple Pay on Safari and iOS in-app browsers.

## Approach
- Add Apple Pay button when the browser supports it.
- Handle the payment token via Stripe.

## Tasks
- [x] Where the browser supports Apple Pay, the Billing shall offer Apple Pay on the checkout page.
- [x] When an Apple Pay token is submitted, the Billing shall exchange it via Stripe and complete the order.
