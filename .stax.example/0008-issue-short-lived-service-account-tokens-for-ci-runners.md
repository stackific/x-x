---
title: Issue short lived service account tokens for CI runners
status: valid
systems: [auth-service]
created: 2025-06-22T08:12:04Z
---

## Goal
Let CI workloads authenticate with short-lived bearer tokens minted per job instead of long-lived shared secrets.

## Approach
- Expose a mint endpoint authenticated by a job-claim JWT.
- Cap token TTL at one hour.

## Tasks
- [x] When a CI runner presents a valid job-claim JWT, the Auth Service shall mint a service account token with a one-hour TTL.
- [x] If a CI runner requests a TTL longer than one hour, then the Auth Service shall clamp the TTL to one hour.
