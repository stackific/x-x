---
title: Add account deletion endpoint compliant with GDPR
status: valid
systems: [auth-service]
created: 2025-07-31T03:39:26Z
---

## Goal
Provide a user-facing delete-my-account endpoint that anonymises the account record and revokes all sessions immediately.

## Approach
- Anonymise PII columns in place.
- Revoke every active session and refresh token.

## Tasks
- [x] When an account deletion is confirmed, the Auth Service shall anonymise the account's PII columns.
- [x] When an account is anonymised, the Auth Service shall revoke every active session and refresh token.
