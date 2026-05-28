---
title: Track delivery receipts for SMS messages
status: valid
systems: [notification-bus]
extends: [0085-add-sms-delivery-channel-for-two-factor-codes]
created: 2026-05-08T14:30:00Z
---

## Goal
Close the feedback loop on the SMS channel 0085 ships by tracking delivery receipts the provider sends back.

## Approach
- Subscribe to Twilio's delivery webhook.
- Record receipt per message id.

## Tasks
- [x] When the SMS provider posts a delivery receipt, the Notification Bus shall record it against the message id.
- [x] If a receipt reports failure, the Notification Bus shall flag the message for follow-up.
