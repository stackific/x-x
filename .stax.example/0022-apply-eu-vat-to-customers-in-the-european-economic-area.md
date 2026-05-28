---
title: Apply EU VAT to customers in the European Economic Area
status: superseded
systems: [billing]
superseded_by: [0034-add-stripe-tax-integration-for-sales-tax-compliance]
created: 2025-08-26T11:00:00Z
---

## Goal
Apply the correct VAT rate to EEA customers based on their billing country.

## Approach
- Look up the rate by country.
- Add a VAT line to the invoice.

## Tasks
- [x] When the Billing finalises an invoice for an EEA customer, the Billing shall add a VAT line at the country rate.
- [x] If the country rate changes mid-cycle, the Billing shall apply the new rate from the next cycle.
