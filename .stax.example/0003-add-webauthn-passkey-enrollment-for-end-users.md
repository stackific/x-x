---
title: Add WebAuthn passkey enrollment for end users
status: valid
systems: [auth-service]
created: 2025-06-11T10:00:55Z
---

## Goal
Let users register a platform passkey as an additional authentication factor and use it for subsequent sign-ins.

## Approach
- Expose enrollment and assertion endpoints.
- Store credential ids and public keys per user.

## Tasks
- [x] When a user enrolls a passkey, the Auth Service shall store its credential id and public key.
- [x] When a user signs in with a passkey assertion, the Auth Service shall verify the assertion against the stored public key.
- [x] If a passkey assertion signature is invalid, then the Auth Service shall reject the sign-in attempt.
