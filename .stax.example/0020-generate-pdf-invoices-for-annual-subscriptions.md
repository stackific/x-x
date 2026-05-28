---
title: Generate PDF invoices for annual subscriptions
status: valid
systems: [billing]
created: 2025-08-15T04:19:23Z
---

## Goal
Produce a PDF invoice on every annual subscription renewal and email it to the billing contact.

## Approach
- Render a branded PDF from the invoice template.
- Email it via the notification bus.

## Tasks
- [x] When an annual subscription renews, the Billing shall generate a PDF invoice from the rendered template.
- [x] When a PDF invoice is generated, the Billing shall store it under the customer's invoice history.
