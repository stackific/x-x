---
title: Add audit log entries for every credential change
status: valid
systems: [auth-service]
created: 2025-06-28T02:41:33Z
---

## Goal
Record every password reset, MFA enrollment, and passkey change so security can reconstruct an account's credential history.

## Approach
- Emit a structured audit record per credential mutation.
- Include before/after fingerprints (never raw secrets).

## Tasks
- [x] When a credential is changed, the Auth Service shall write an audit record with actor, target, and event type.
- [x] When the audit record is written, the Auth Service shall include a fingerprint of the new credential.
- [x] If the audit sink is unavailable, then the Auth Service shall reject the credential change.
