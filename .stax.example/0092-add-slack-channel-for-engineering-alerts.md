---
title: Add Slack channel for engineering alerts
status: valid
systems: [notification-bus]
created: 2026-05-08T15:07:18Z
---

## Goal
Route engineering alerts to a configured Slack channel with thread continuity per incident.

## Approach
- Add the Slack channel integration.
- Thread alerts by incident id.

## Tasks
- [x] When an engineering alert is enqueued, the Notification Bus shall post it to the configured Slack channel.
- [x] When an alert has an incident id, the Notification Bus shall post it as a reply on the incident thread.
