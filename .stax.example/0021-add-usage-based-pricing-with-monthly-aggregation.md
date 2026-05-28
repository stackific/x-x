---
title: Add usage based pricing with monthly aggregation
status: valid
systems: [billing]
created: 2025-08-16T10:31:12Z
---

## Goal
Allow per-plan usage meters that aggregate over the calendar month and bill the customer at month end.

## Approach
- Record usage events with idempotency keys.
- Aggregate by meter on month-end close.

## Tasks
- [x] When a usage event arrives, the Billing shall record it against the customer's current month meter.
- [x] When the calendar month closes, the Billing shall sum each meter and add the total as an invoice line.
- [x] If a duplicate usage event arrives, then the Billing shall ignore it based on its idempotency key.
