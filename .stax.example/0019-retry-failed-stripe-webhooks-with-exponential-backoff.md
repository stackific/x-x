---
title: Retry failed Stripe webhooks with exponential backoff
status: valid
systems: [billing]
created: 2025-08-14T07:26:30Z
---

## Goal
Recover from transient Stripe webhook delivery failures by retrying processing up to five times with exponential backoff.

## Approach
- Queue failed webhooks with attempt counter.
- Cap retries at five.

## Tasks
- [x] When webhook processing throws a transient error, the Billing shall enqueue the webhook for retry with exponential backoff.
- [x] If a webhook has failed five times, then the Billing shall move it to a dead-letter table for manual review.
