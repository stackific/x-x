---
title: Reconcile Stripe payouts daily against ledger entries
status: valid
systems: [billing]
extends: [0019-retry-failed-stripe-webhooks-with-exponential-backoff]
created: 2025-09-14T10:24:55Z
---

## Goal
Catch ledger drift early by reconciling Stripe payouts against our internal ledger every day. Builds on the reliable webhook delivery 0019 established.

## Approach
- Pull the payout list from Stripe each morning.
- Diff against ledger entries for the same window.

## Tasks
- [x] When the daily reconciliation job runs, the Billing shall fetch the previous day's Stripe payouts.
- [x] If a Stripe payout has no matching ledger entry, the Billing shall raise a reconciliation finding.
