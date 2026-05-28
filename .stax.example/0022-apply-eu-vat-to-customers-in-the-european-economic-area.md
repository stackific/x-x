---
title: Apply EU VAT to customers in the European Economic Area
status: valid
systems: [billing]
created: 2025-08-18T09:06:55Z
---

## Goal
Charge the correct VAT rate for each EEA customer based on billing country and surface the rate on the invoice.

## Approach
- Maintain a VAT-rate table by country.
- Add a tax line per invoice.

## Tasks
- [x] While a customer's billing country is inside the EEA, the Billing shall add a VAT line at the country's current rate.
- [x] When the rate table is updated, the Billing shall use the new rate on invoices issued after the update.
