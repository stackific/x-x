---
title: Apply proration when customers upgrade mid cycle
status: valid
systems: [billing]
created: 2025-08-13T22:45:37Z
---

## Goal
When a customer upgrades to a higher plan in the middle of a billing cycle, credit the unused portion of the previous plan against the new charge.

## Approach
- Compute daily-rate credit for the unused portion.
- Apply the credit on the next invoice.

## Tasks
- [x] When a customer upgrades mid cycle, the Billing shall compute a daily-rate credit for the unused days of the previous plan.
- [x] When the next invoice is generated, the Billing shall apply the credit before charging the new plan.
