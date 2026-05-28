---
title: Enforce multi factor authentication on all admin accounts
status: valid
systems: [auth-service]
created: 2025-06-14T00:50:36Z
---

## Goal
Every account with the admin role must complete a second factor on each sign-in within thirty days.

## Approach
- Add an admin-role MFA enforcement gate.
- Block password-only sign-ins for admins after the deadline.

## Tasks
- [x] While an account holds the admin role, the Auth Service shall require a second factor on every sign-in.
- [x] If an admin attempts a password-only sign-in after the deadline, then the Auth Service shall block the session and prompt enrollment.
