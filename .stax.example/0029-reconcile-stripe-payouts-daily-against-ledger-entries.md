---
title: Reconcile Stripe payouts daily against ledger entries
status: valid
systems: [billing]
created: 2025-09-07T16:26:40Z
---

## Goal
Confirm that every Stripe payout corresponds to ledger entries on this side, flagging mismatches for finance review.

## Approach
- Pull yesterday's payouts each morning.
- Compare totals against the ledger.

## Tasks
- [x] When the daily reconciliation runs, the Billing shall compare every Stripe payout against the ledger.
- [x] If a payout total does not match the ledger, then the Billing shall raise a reconciliation alert.
