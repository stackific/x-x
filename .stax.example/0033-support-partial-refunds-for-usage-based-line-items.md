---
title: Support partial refunds for usage-based line items
status: valid
systems: [billing]
extends: [0021-add-usage-based-pricing-with-monthly-aggregation]
created: 2025-10-09T14:50:00Z
---

## Goal
Let support agents refund a portion of a single usage line item without unwinding the whole invoice. Builds on the per-SKU line structure 0021 introduced.

## Approach
- Refund against a single line + quantity.
- Cap the refund at the line's original amount.

## Tasks
- [x] When an agent requests a partial refund on a usage line, the Billing shall refund the requested quantity at the line's unit price.
- [x] If the requested refund exceeds the line amount, then the Billing shall reject the request.
