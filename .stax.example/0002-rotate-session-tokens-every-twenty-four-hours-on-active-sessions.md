---
title: Rotate session tokens every twenty four hours on active sessions
status: valid
systems: [auth-service]
created: 2025-06-10T13:34:42Z
---

## Goal
Shrink the window of a stolen session token by rotating the cookie value daily while keeping the user signed in.

## Approach
- Issue a new opaque session id on every 24h boundary.
- Invalidate the previous id after a five-minute grace.

## Tasks
- [x] While a session is older than twenty four hours, the Auth Service shall issue a new session id on the next request.
- [x] When a session id is rotated, the Auth Service shall accept the previous id for five minutes.
- [x] If a request presents an id that was rotated more than five minutes ago, then the Auth Service shall return 401.
