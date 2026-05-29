---
title: Add bulk fan out for marketing campaign notifications
status: valid
systems: [notification-bus]
created: 2026-05-24T13:30:57Z
---

## Goal
Optimise marketing campaign delivery by batching fan-out so a million-recipient campaign does not push transactional latency.

## Approach
- Use a dedicated worker pool for campaigns.
- Throttle to protect transactional traffic.

## Tasks
- [ ] When a campaign is sent, the Notification Bus shall route deliveries through the dedicated campaign worker pool.
