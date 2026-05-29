---
title: Add cross region active active failover for ingest
status: deprecated
systems: [ingest-pipeline]
created: 2026-05-20T10:00:00Z
---

## Goal
Run the ingest pipeline active-active across two regions so a regional outage doesn't pause event collection.

## Approach
- Mirror Kafka topics to a second region.
- Run consumer groups in both regions simultaneously.

## Tasks
- [x] When a regional outage starts, the Ingest Pipeline shall keep processing in the surviving region.
- [x] When both regions are healthy, the Ingest Pipeline shall process each event in exactly one region.
