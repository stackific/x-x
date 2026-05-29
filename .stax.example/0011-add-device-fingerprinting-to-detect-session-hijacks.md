---
title: Add device fingerprinting to detect session hijacks
status: valid
systems: [auth-service]
created: 2025-07-10T14:27:21Z
---

## Goal
Detect probable session theft by comparing a hashed device fingerprint against the one captured at sign-in.

## Approach
- Capture a fingerprint on sign-in.
- Compare on each request.

## Tasks
- [x] When a session is created, the Auth Service shall store a hashed device fingerprint.
- [x] If a request presents a fingerprint that does not match the stored value, then the Auth Service shall require re-authentication.
