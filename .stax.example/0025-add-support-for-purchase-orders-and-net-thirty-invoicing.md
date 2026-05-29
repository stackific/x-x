---
title: Add support for purchase orders and net thirty invoicing
status: valid
systems: [billing]
created: 2025-09-02T05:47:42Z
---

## Goal
Allow enterprise customers to pay via purchase order with a net-30 grace period instead of card-on-file.

## Approach
- Issue invoices with PO numbers and 30-day due dates.
- Defer service suspension until past-due plus seven days.

## Tasks
- [x] When an invoice is issued to a net-30 customer, the Billing shall set the due date thirty days out.
- [x] While an invoice is within its grace period, the Billing shall not suspend the account.
- [x] If an invoice is past due by more than seven days, then the Billing shall flag the account for suspension review.
