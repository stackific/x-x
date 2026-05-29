---
title: Add backpressure handling for traffic spikes
status: valid
systems: [ingest-pipeline]
extends: [0051-add-kafka-consumer-for-clickstream-events]
created: 2026-01-08T22:40:00Z
---

## Goal
Cap downstream pressure during traffic spikes by pausing the existing Kafka consumer when warehouse load exceeds a threshold.

## Approach
- Read the warehouse load gauge.
- Pause consumption while the gauge is hot.

## Tasks
- [x] While the warehouse load gauge exceeds 0.8, the Ingest Pipeline shall pause Kafka consumption.
- [x] When the gauge falls below 0.5, the Ingest Pipeline shall resume consumption.
