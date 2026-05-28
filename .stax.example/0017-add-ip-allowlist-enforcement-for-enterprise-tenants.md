---
title: Add IP allowlist enforcement for enterprise tenants
status: valid
systems: [auth-service]
created: 2025-08-10T07:14:55Z
---

## Goal
Let enterprise customers restrict sign-in to a configured set of CIDR ranges per tenant.

## Approach
- Add a CIDR allowlist field to tenant config.
- Block sign-ins from disallowed IPs.

## Tasks
- [x] While a tenant has an IP allowlist configured, the Auth Service shall allow sign-ins only from the listed CIDRs.
- [x] If a sign-in attempt arrives from outside the allowlist, then the Auth Service shall reject the attempt with ip_not_allowed.
