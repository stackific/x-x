---
title: Add Google Workspace SAML connector
status: valid
systems: [auth-service]
created: 2025-06-20T07:52:38Z
---

## Goal
Let customers on Google Workspace federate sign-in through SAML 2.0 instead of provisioning local accounts.

## Approach
- Add SAML metadata endpoint per tenant.
- Map asserted email to tenant user record.

## Tasks
- [x] When a SAML assertion arrives, the Auth Service shall validate the signature against the tenant's IdP certificate.
- [x] When the email claim matches an existing user, the Auth Service shall issue a session for that user.
- [x] If the assertion signature is invalid, then the Auth Service shall reject the sign-in.
