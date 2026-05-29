---
title: Add feature store canary rollback watcher
status: valid
systems: [feature-store]
extends: [0081-add-canary-feature-deployment-workflow]
created: 2026-05-27T05:55:44Z
---

## Goal
Automatically roll back a canary feature deployment when the watcher sees regression metrics breach the canary thresholds. Builds on the canary workflow 0081 ships.

## Approach
- Poll regression metrics every minute during canary.
- Roll back when a threshold trips.

## Tasks
- [x] While a canary feature is live, the Feature Store shall sample regression metrics every minute.
- [x] If a regression metric breaches its threshold, the Feature Store shall roll the canary back automatically.
