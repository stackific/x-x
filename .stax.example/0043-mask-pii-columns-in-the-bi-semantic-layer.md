---
title: Mask PII columns in the BI semantic layer
status: valid
systems: [analytics-warehouse]
created: 2025-10-22T01:51:17Z
---

## Goal
Apply row-level and column-level masking to PII so analysts without elevated roles cannot read raw email addresses or names.

## Approach
- Apply masking policies in the semantic layer.
- Audit policy bypass attempts.

## Tasks
- [x] While an analyst lacks the elevated role, the Analytics Warehouse shall mask the email and name columns.
- [x] If an unauthorised query attempts to bypass masking, then the Analytics Warehouse shall log an audit event.
