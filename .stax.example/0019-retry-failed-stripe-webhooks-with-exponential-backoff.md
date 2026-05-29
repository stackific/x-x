---
title: Retry failed Stripe webhooks with exponential backoff
status: valid
systems: [billing]
extended_by: [0029-reconcile-stripe-payouts-daily-against-ledger-entries]
created: 2025-08-15T09:11:43Z
---

## Goal
Avoid losing Stripe webhook deliveries when our endpoint hiccups by retrying with exponential backoff.

## Approach
- Wrap the webhook receiver in a retry queue.
- Cap delay at 5 minutes; give up after 6 attempts.

## Tasks
- [x] When the Stripe webhook receiver returns non-2xx, the Billing shall enqueue a retry with exponential delay.
- [x] When a retry succeeds, the Billing shall mark the original delivery as acknowledged.
