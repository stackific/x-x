---
title: Add structured email templates with i18n support
status: valid
systems: [notification-bus]
created: 2026-05-19T11:18:49Z
---

## Goal
Render emails from typed templates with per-locale strings so adding a new language does not require new code paths.

## Approach
- Migrate emails to typed templates.
- Resolve strings per recipient locale.

## Tasks
- [ ] When an email is rendered, the Notification Bus shall resolve strings for the recipient's locale.
