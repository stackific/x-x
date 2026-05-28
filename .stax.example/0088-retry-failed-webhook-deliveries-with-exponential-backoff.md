---
title: Retry failed webhook deliveries with exponential backoff
status: valid
systems: [notification-bus]
created: 2026-05-03T16:17:06Z
---

## Goal
Tolerate transient outages on customer webhook endpoints by retrying delivery with exponential backoff up to twenty four hours.

## Approach
- Schedule retries on a backoff curve.
- Stop after twenty four hours.

## Tasks
- [x] When a webhook delivery fails with a transient error, the Notification Bus shall retry the delivery on an exponential backoff.
- [x] If a webhook has failed continuously for twenty four hours, then the Notification Bus shall mark the destination as broken.
