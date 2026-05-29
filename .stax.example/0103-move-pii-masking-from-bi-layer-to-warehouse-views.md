---
title: Move PII masking from BI layer to warehouse views
status: valid
systems: [analytics-warehouse]
supersedes: [0043-mask-pii-columns-in-the-bi-semantic-layer]
created: 2026-05-27T03:55:44Z
---

## Goal
Push PII masking down from the BI semantic layer to warehouse views so every consumer (BI, notebooks, ad-hoc queries) sees masked data by default rather than the BI tool being the single point of enforcement.

## Approach
- Recreate sensitive tables as views with mask functions applied.
- Drop direct grants on the base tables.

## Tasks
- [x] When a sensitive table is queried, the Analytics Warehouse shall return masked values for PII columns.
- [x] If a caller has the unmask role, the Analytics Warehouse shall return the raw column value.
