---
title: Add rate limiting on the password reset endpoint
status: valid
systems: [auth-service]
created: 2025-07-20T14:31:58Z
---

## Goal
Defend the password reset flow from enumeration and SMS-bombing by limiting requests per email and per source IP.

## Approach
- Apply a sliding window counter per email and per IP.
- Return 429 with retry hints.

## Tasks
- [x] While more than three reset requests have been made for the same email in fifteen minutes, the Auth Service shall return 429.
- [x] While more than ten reset requests have been made from the same IP in fifteen minutes, the Auth Service shall return 429.
