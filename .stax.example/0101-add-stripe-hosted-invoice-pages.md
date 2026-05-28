---
title: Add Stripe hosted invoice pages
status: valid
systems: [billing]
supersedes: [0020-generate-pdf-invoices-for-annual-subscriptions]
created: 2026-05-10T09:00:00Z
---

## Goal
Replace the server-side PDF generator with Stripe-hosted invoice pages so customers always see the same invoice format Stripe ships.

## Approach
- Stop generating PDFs on cycle close.
- Send the Stripe hosted-invoice URL in the customer email.

## Tasks
- [x] When an invoice is finalised, the Billing shall record the Stripe hosted-invoice URL.
- [x] When a renewal email is sent, the Billing shall include the hosted-invoice URL instead of an attachment.
