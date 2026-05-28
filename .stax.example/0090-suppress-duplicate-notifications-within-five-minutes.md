---
title: Suppress duplicate notifications within five minutes
status: valid
systems: [notification-bus]
created: 2026-05-07T10:32:29Z
---

## Goal
Avoid sending the same notification body to the same recipient within a five-minute window.

## Approach
- Hash recipient plus body.
- Suppress matching hashes.

## Tasks
- [x] If a notification with the same recipient and body arrives within five minutes of a previous one, then the Notification Bus shall drop the duplicate.
