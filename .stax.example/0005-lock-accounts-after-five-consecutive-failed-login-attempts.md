---
title: Lock accounts after five consecutive failed login attempts
status: valid
systems: [auth-service]
created: 2025-06-14T23:43:03Z
---

## Goal
Defend against credential stuffing by locking an account for fifteen minutes after five failed password attempts in a row.

## Approach
- Track failure counter per account id.
- Reset the counter on a successful sign-in.

## Tasks
- [x] When an account has five consecutive failed sign-ins, the Auth Service shall lock the account for fifteen minutes.
- [x] When a successful sign-in occurs, the Auth Service shall reset the failure counter.
- [x] If a sign-in is attempted on a locked account, then the Auth Service shall return account_locked without revealing whether the password was correct.
