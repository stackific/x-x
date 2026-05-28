---
title: Support magic link sign in for read only users
status: valid
systems: [auth-service]
created: 2025-07-13T00:44:13Z
---

## Goal
Allow read-only roles to sign in via a one-time link sent to their email, skipping the password requirement.

## Approach
- Generate a single-use, time-limited token.
- Restrict the resulting session to read-only scopes.

## Tasks
- [x] When a read-only user requests a magic link, the Auth Service shall email a single-use token valid for ten minutes.
- [x] When a magic link is consumed, the Auth Service shall issue a session limited to read-only scopes.
- [x] If a magic link is used twice, then the Auth Service shall reject the second use.
