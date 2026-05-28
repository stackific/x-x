---
title: Add tax exempt customer flag for nonprofits and resellers
status: valid
systems: [billing]
created: 2025-09-10T07:42:19Z
---

## Goal
Skip tax calculation for customers that have provided a valid exemption certificate.

## Approach
- Add a tax-exempt boolean and certificate reference per customer.
- Skip the VAT and sales tax lines when set.

## Tasks
- [x] While a customer is marked tax-exempt, the Billing shall omit tax lines from their invoices.
- [x] If a tax-exempt customer's certificate has expired, then the Billing shall resume charging tax.
