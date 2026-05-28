---
title: Add OpenTelemetry tracing to the ingest workers
status: valid
systems: [ingest-pipeline]
created: 2025-12-22T08:35:10Z
---

## Goal
Add OpenTelemetry trace spans to each ingest worker so the end-to-end latency from Kafka offset to warehouse insert is observable.

## Approach
- Wrap consume, parse, and write with spans.
- Export to the central OTLP collector.

## Tasks
- [x] When the Ingest Pipeline consumes an event, the Ingest Pipeline shall emit an OpenTelemetry span covering consume, parse, and write.
