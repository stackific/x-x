---
title: Issue refunds within thirty days without manual approval
status: valid
systems: [billing]
created: 2025-09-04T02:21:08Z
---

## Goal
Process customer-initiated refund requests automatically when the original charge is less than thirty days old.

## Approach
- Add a self-serve refund endpoint.
- Cap auto-refunds to the original charge amount.

## Tasks
- [x] When a customer requests a refund for a charge less than thirty days old, the Billing shall issue the refund without manual approval.
- [x] If the refund amount exceeds the original charge, then the Billing shall reject the request.
