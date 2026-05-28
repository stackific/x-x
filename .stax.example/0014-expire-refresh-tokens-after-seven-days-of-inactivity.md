---
title: Expire refresh tokens after seven days of inactivity
status: valid
systems: [auth-service]
created: 2025-07-30T14:49:48Z
---

## Goal
Keep long-lived refresh tokens from outliving their usefulness by expiring any that go unused for seven days.

## Approach
- Track last-use timestamp on every refresh.
- Reject stale refreshes.

## Tasks
- [x] When a refresh token is exchanged, the Auth Service shall update its last-use timestamp.
- [x] If a refresh token has not been used in seven days, then the Auth Service shall reject the exchange.
