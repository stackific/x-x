---
title: Generate PDF invoices for annual subscriptions
status: superseded
systems: [billing]
superseded_by: [0101-add-stripe-hosted-invoice-pages]
created: 2025-08-19T15:33:21Z
---

## Goal
Generate a server-side PDF invoice for every annual subscription and email it to the customer on cycle close.

## Approach
- Render the invoice HTML.
- Convert to PDF and attach to the email.

## Tasks
- [x] When an annual subscription cycle closes, the Billing shall render an invoice PDF.
- [x] When the PDF is ready, the Billing shall email it to the customer.
