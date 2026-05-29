---
title: Move card on file management out of the checkout flow
status: valid
systems: [billing]
created: 2025-09-11T17:12:44Z
---

## Goal
Separate card management from checkout into a dedicated settings screen so adding a card is not bundled with making a purchase.

## Approach
- Expose CRUD endpoints for cards.
- Remove inline 'save my card' UI from checkout.

## Tasks
- [x] When a customer adds a card from settings, the Billing shall tokenise it via Stripe and store the token.
- [x] When a customer deletes a card, the Billing shall revoke the Stripe token and remove the record.
