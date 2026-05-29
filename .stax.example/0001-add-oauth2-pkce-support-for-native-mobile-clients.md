---
title: Add OAuth2 PKCE support for native mobile clients
status: valid
systems: [auth-service]
created: 2025-05-28T17:26:42Z
---

## Goal
Allow iOS and Android clients to complete the OAuth2 authorization code flow without a confidential client secret by requiring PKCE.

## Approach
- Accept S256 PKCE code challenges on the authorize endpoint.
- Require the code verifier on the token exchange.
- Reject plain-text PKCE method to enforce S256.

## Tasks
- [x] When a native client initiates authorization, the Auth Service shall require an S256 code challenge.
- [x] When the token exchange omits the code verifier, the Auth Service shall reject the request with invalid_grant.
- [x] If a client submits a plain code challenge method, then the Auth Service shall reject the authorization request.
