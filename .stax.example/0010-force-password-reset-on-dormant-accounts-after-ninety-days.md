---
title: Force password reset on dormant accounts after ninety days
status: valid
systems: [auth-service]
created: 2025-07-03T09:52:03Z
---

## Goal
Reduce risk from forgotten accounts by forcing a password reset if no sign-in has occurred for ninety days.

## Approach
- Mark dormant accounts on the daily reaper.
- Block sign-in until reset is completed.

## Tasks
- [x] While an account has been inactive for ninety days, the Auth Service shall require a password reset on next sign-in.
- [x] When the reset completes, the Auth Service shall clear the dormant flag.
