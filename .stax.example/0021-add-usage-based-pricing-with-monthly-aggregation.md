---
title: Add usage-based pricing with monthly aggregation
status: valid
systems: [billing]
extended_by: [0033-support-partial-refunds-for-usage-based-line-items]
created: 2025-08-23T08:30:00Z
---

## Goal
Bill customers for measured usage at the end of each month with one line item per metered SKU.

## Approach
- Track per-tenant usage counters.
- Emit one invoice line per SKU on cycle close.

## Tasks
- [x] When a usage event arrives, the Billing shall increment the tenant counter for its SKU.
- [x] When the billing cycle closes, the Billing shall emit one invoice line per metered SKU.
