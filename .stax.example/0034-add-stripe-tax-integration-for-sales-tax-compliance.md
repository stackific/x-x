---
title: Add Stripe Tax integration for sales tax compliance
status: valid
systems: [billing]
supersedes: [0030-add-tax-exempt-customer-flag-for-nonprofits-and-resellers]
created: 2025-09-19T13:56:58Z
---

## Goal
Replace the home-grown US sales tax calculator with Stripe Tax so rates, nexus tracking, and exemption certificates stay current automatically.

## Approach
- Call the Stripe Tax preview on every invoice.
- Persist returned line items on the invoice.
- Forward exemption certificates so Stripe applies the right zero-rated treatment.

## Tasks
- [x] When an invoice is finalised, the Billing shall request a tax calculation from Stripe Tax.
- [x] When Stripe Tax returns tax lines, the Billing shall attach them to the invoice.
- [x] When a customer has an active exemption certificate, the Billing shall include it on the Stripe Tax request.
