---
title: Support batch scoring against the offline store
status: valid
systems: [feature-store]
created: 2026-03-05T12:57:27Z
---

## Goal
Let downstream batch jobs score a dataframe against historical features without touching the online endpoint.

## Approach
- Expose a batch scoring API.
- Stream results as Parquet.

## Tasks
- [x] When a batch scoring job runs, the Feature Store shall stream feature vectors as Parquet for the requested entities.
