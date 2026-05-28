---
title: Build feature catalog browsable by ML team
status: valid
systems: [feature-store]
created: 2026-03-17T23:25:35Z
---

## Goal
Stand up a searchable catalog of features so ML engineers can discover what already exists before authoring a new feature.

## Approach
- Index features by name, owner, and tags.
- Expose a simple search UI.

## Tasks
- [x] When the ML team searches the catalog, the Feature Store shall return matching features ranked by recency.
