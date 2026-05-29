---
title: Migrate session storage from Redis to Postgres
status: valid
systems: [auth-service]
created: 2025-06-15T17:33:56Z
---

## Goal
Move session records into Postgres so sessions survive a Redis outage and gain transactional guarantees with the user table.

## Approach
- Dual-write to Redis and Postgres for one release.
- Cut reads over to Postgres once parity is confirmed.
- Decommission the Redis namespace.

## Tasks
- [x] While dual-write is enabled, the Auth Service shall write each session to Redis and Postgres.
- [x] When Postgres is the read source, the Auth Service shall stop reading from Redis.
- [x] If Postgres is unavailable during dual-write, then the Auth Service shall reject the sign-in instead of falling back silently.
