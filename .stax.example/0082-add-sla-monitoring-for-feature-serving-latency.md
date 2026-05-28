---
title: Add SLA monitoring for feature serving latency
status: valid
systems: [feature-store]
created: 2026-04-07T08:34:19Z
---

## Goal
Page on-call when feature serving p99 latency exceeds fifty milliseconds for five minutes.

## Approach
- Export p99 from the online endpoint.
- Page on threshold breach.

## Tasks
- [x] If feature serving p99 latency exceeds fifty milliseconds for five minutes, then the Feature Store shall page the on-call rotation.
