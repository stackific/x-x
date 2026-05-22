---
# SPDX-License-Identifier: Apache-2.0
name: x-plan
description: Plan-first workflow for this repo. Loads the shared planning context, then writes a tightly-scoped plan following EARS-format tasks. Invoke at the start of any planning or design task.
---

# x-plan

## 1. Load context

Load context per **Context to load** in `.claude/skills/_x-x_shared/_shared_plan_first.md`. If any required file is missing, STOP and report.

## 2. Clarify only when structurally underspecified (skip by default)

Skip this step by default. Trigger it only when the request is genuinely underspecified — ambiguous scope, a system that would need to be proposed to the registry, or a real technology choice with no obvious default. Routine plans don't need clarification.

When clarification IS needed, ask the user all questions in a single `AskUserQuestion` call (the harness's structured-question tool — options with header chips, optional previews). The tool caps at 4 questions per call — sufficient because plans are bounded at 30 lines; needing more than 4 means the scope is too big and the request should split. Each split spec gets its own `AskUserQuestion` call. Never ask in plain prose. Do not write the plan in the same turn as the questions.

## 2a. Check for overlap with valid plans

Run `x-x plan list --status valid`. Compare the new plan's planned `systems` against each emitted row's third column for any intersection.

If any intersection exists, ask the user — in the same single-turn questions batch from step 2 — whether the new plan **extends** or **supersedes** each overlapping plan, referenced by full slug (e.g. `00003-checkout-retry`).

## 2b. Research dependencies and external APIs

Before drafting tasks that reference a specific library, a third-party API, an authentication mechanism, or any external service contract, run `WebSearch` and (where the search points at upstream docs) `WebFetch` to confirm current details. Do NOT trust training-data versions or API shapes — both drift.

Mandatory when the plan touches:
- A new Python dependency — web-search the latest stable release before pinning (AGENTS.md hard rule).
- An external service API (proxy providers, search engines, browser-automation libraries, observability backends, CDN/CI platforms, etc.).
- An authentication format (proxy URL syntax, OAuth flows, HMAC payload layouts, header conventions).
- A platform CLI (`gh`, `docker compose`, `uv`, etc.) where flags or output shape change between versions.

Cite the upstream URLs in the plan's Approach section as parenthetical `(docs: <url>)` notes so the user can audit. If research surfaces a design conflict with the user's stated intent, do not write the plan in the same turn — loop back to step 2 and clarify via `AskUserQuestion`.

## 3. Write the plan(s)

Run `x-x plan next-prefix` to obtain `<prefix>`. Write the plan per **Plan file contract** in `_shared_plan_first.md`: path `.x-plan/<prefix>-<slug>.md`, mandatory frontmatter (`status: valid`, `systems: [...]`), optional `supersedes` when step 2a determined supersession.

**Before drafting the `## Tasks` section, read `.claude/skills/_x-x_shared/_shared_ears.md`.** It is lazy-loaded only here (kept out of step 1) to make context loading cheap; every EARS criterion names exactly one system from `.x-plan/_data_systems.yaml`.

The `systems:` array must list every system named in the plan's EARS tasks, each entry an exact `name` from `.x-plan/_data_systems.yaml`.

If the request covers separable scopes, you may split it into multiple specs — but only when each resulting spec's tasks target a fully disjoint set of systems. If any system would appear in two specs, keep them as one. Run `x-x plan next-prefix` once per split spec, in order, so prefixes stay sequential. Do not split for the sake of splitting.

### Hard rules

- Under 30 lines total.
- Sections only, in this order:
  - `## Goal` — one paragraph.
  - `## Approach` — bullets only, no prose paragraphs.
  - `## Tasks` — EARS format per `.claude/skills/_x-x_shared/_shared_ears.md`.
- **Approach is design narrative; Tasks are deliverables.** Approach describes architecture, technology choices, file layout, mirrored references, etc. Tasks are the units `/x-x` flips. If Approach names a concrete artifact — a file, endpoint, doc, config row, workflow, dependency add — there MUST be at least one EARS task on the same system that makes the artifact's existence (or behavior) observable. Tasks may exist without a covering Approach bullet (that's fine; not every mechanical criterion needs design narrative). Approach bullets without a covering Task are a planning gap — the bullet's deliverable will not be tracked or written. Exception: project-level meta edits (`AGENTS.md`, `.x-plan/_data_systems.yaml`, `.claude/settings.json`, etc.) have no system as their actor and may live in Approach alone — they have no covering Task.
- No "Considerations", "Risks", "Out of Scope", "Future Work", "Background", or preamble.
- Do not restate the user's request.
