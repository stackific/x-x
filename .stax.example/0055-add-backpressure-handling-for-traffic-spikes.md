---
title: Add backpressure handling for traffic spikes
status: valid
systems: [ingest-pipeline]
created: 2025-12-10T11:04:23Z
---

## Goal
Cap downstream pressure during traffic spikes by pausing consumption when warehouse load exceeds a threshold.

## Approach
- Read the warehouse load gauge.
- Pause consumption while the gauge is hot.

## Tasks
- [x] While the warehouse load gauge exceeds 0.8, the Ingest Pipeline shall pause Kafka consumption.
- [x] When the gauge falls below 0.5, the Ingest Pipeline shall resume consumption.
