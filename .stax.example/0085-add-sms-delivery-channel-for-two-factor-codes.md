---
title: Add SMS delivery channel for two factor codes
status: valid
systems: [notification-bus]
extended_by: [0091-track-delivery-receipts-for-sms-messages]
created: 2026-04-23T10:00:00Z
---

## Goal
Send two-factor codes by SMS so users without an authenticator app can still verify.

## Approach
- Plug Twilio in as the SMS provider.
- Format the message to a 6-digit code.

## Tasks
- [x] When a 2FA challenge starts, the Notification Bus shall send the code over SMS.
- [x] If the SMS provider rejects the send, the Notification Bus shall surface a delivery error.
