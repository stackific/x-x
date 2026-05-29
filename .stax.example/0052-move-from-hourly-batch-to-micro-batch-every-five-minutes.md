---
title: Move from hourly batch to micro batch every five minutes
status: valid
systems: [ingest-pipeline]
created: 2026-01-08T19:40:00Z
---

## Goal
Shrink the data freshness window from one hour to five minutes by running the batch loader every five minutes.

## Approach
- Tune the loader to small windows.
- Verify the warehouse can absorb the cadence.

## Tasks
- [x] When five minutes have elapsed since the last load, the Ingest Pipeline shall start the next micro-batch.
- [x] If a micro-batch overruns its five-minute window, then the Ingest Pipeline shall raise a lag alert.
