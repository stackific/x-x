---
title: Migrate password hashing from bcrypt to argon2id
status: valid
systems: [auth-service]
created: 2025-08-03T05:23:51Z
---

## Goal
Upgrade the password hash to argon2id, rehashing on next successful sign-in to avoid forcing a global reset.

## Approach
- Support both bcrypt and argon2id verification.
- Rehash to argon2id on successful sign-in.

## Tasks
- [x] When a user signs in with a bcrypt-hashed password, the Auth Service shall rehash the password using argon2id.
- [x] When a new password is set, the Auth Service shall store its argon2id hash.
