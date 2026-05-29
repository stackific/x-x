---
title: Add Kafka consumer for clickstream events
status: valid
systems: [ingest-pipeline]
extended_by: [0055-add-backpressure-handling-for-traffic-spikes]
created: 2025-11-20T15:22:02Z
---

## Goal
Read clickstream events from the new Kafka topic and land them in the bronze layer for downstream analytics.

## Approach
- Subscribe to the clickstream topic.
- Write to the bronze partition by event date.

## Tasks
- [x] When a clickstream event arrives on Kafka, the Ingest Pipeline shall write it to the bronze partition for its event date.
