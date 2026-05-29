---
title: Auto scale Kafka consumer groups based on lag
status: valid
systems: [ingest-pipeline]
created: 2026-01-11T04:12:01Z
---

## Goal
Scale consumer pods up when topic lag grows and back down once it drains, instead of provisioning for peak.

## Approach
- Drive HPA off the lag metric.
- Cap maximum replicas.

## Tasks
- [x] While topic lag exceeds the warning threshold, the Ingest Pipeline shall increase consumer replicas.
- [x] When topic lag returns to baseline, the Ingest Pipeline shall scale consumer replicas back down.
