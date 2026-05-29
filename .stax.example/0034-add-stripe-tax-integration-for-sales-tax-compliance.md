---
title: Add Stripe Tax integration for sales tax compliance
status: valid
systems: [billing]
supersedes: [0022-apply-eu-vat-to-customers-in-the-european-economic-area, 0030-add-tax-exempt-customer-flag-for-nonprofits-and-resellers]
created: 2025-09-19T13:56:58Z
---

## Goal
Replace the home-grown US sales tax calculator AND the bespoke EU VAT handler with Stripe Tax so rates, nexus tracking, and exemption certificates stay current automatically across every jurisdiction.

## Approach
- Call the Stripe Tax preview on every invoice.
- Persist returned line items on the invoice.

## Tasks
- [x] When an invoice is finalised, the Billing shall request a tax calculation from Stripe Tax.
- [x] When Stripe Tax returns tax lines, the Billing shall attach them to the invoice.
