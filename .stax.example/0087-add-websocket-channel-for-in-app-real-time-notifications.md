---
title: Add WebSocket channel for in app real time notifications
status: valid
systems: [notification-bus]
created: 2026-04-30T12:22:34Z
---

## Goal
Push in-app notifications to connected clients over WebSockets so users see updates without polling.

## Approach
- Add a WebSocket gateway.
- Fan out per user session.

## Tasks
- [x] When a user is connected via WebSocket, the Notification Bus shall deliver in-app notifications over the open connection.
