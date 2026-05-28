---
title: Support partial refunds for usage based line items
status: valid
systems: [billing]
created: 2025-09-18T01:33:25Z
---

## Goal
Allow finance to refund a specific portion of a usage line item without refunding the whole invoice.

## Approach
- Accept a partial refund amount per line.
- Re-issue an invoice memo for the adjustment.

## Tasks
- [x] When finance issues a partial refund for a usage line, the Billing shall reduce the line by the requested amount.
- [x] If the requested amount exceeds the line total, then the Billing shall reject the refund.
