---
title: Add subscription pause feature for up to three months
status: valid
systems: [billing]
created: 2025-09-05T03:24:12Z
---

## Goal
Let customers pause an active subscription for one, two, or three months without losing their settings.

## Approach
- Suspend billing while paused.
- Auto-resume on the chosen date.

## Tasks
- [x] When a customer pauses a subscription, the Billing shall stop generating invoices until the resume date.
- [x] When the resume date arrives, the Billing shall reactivate the subscription and resume invoicing.
- [x] If a customer attempts to pause for more than three months, then the Billing shall reject the request.
