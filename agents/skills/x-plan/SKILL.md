---
# SPDX-License-Identifier: Apache-2.0
name: x-plan
description: Plan-first workflow for this repo. Loads the shared planning context, then writes a tightly-scoped plan following EARS-format tasks. Invoke at the start of any planning or design task.
---

# x-plan

## 1. Load context

Skills install into a folder we call `<skills_root>`, which is either `.claude/skills/` (Claude Code) or `.agents/skills/` (other agents).

`<skills_root>` can exist at two scopes:
- **Project scope**: `<cwd>/.claude/skills/` or `<cwd>/.agents/skills/`
- **User scope**: `.claude/skills/` or `.agents/skills/` in the user's home directory

When a reference like `../_x-x_shared/...` appears, resolve it against `<skills_root>/_x-x_shared/`. Check project scope first, then user scope. If the file is missing from both, STOP and report to the user.

Now load context per **Context to load** in `../_x-x_shared/_plan_first.md`.

Additionally, read `<cwd>/.x-plans/_config.lock` and extract `max_plan_lines` (integer). If the lock file is missing, STOP and tell the user this directory isn't set up for x-x yet — they need to run `x-x init`. If the file exists but the key is absent or non-positive, fall back to `30` (matches `x-x plans lint`). Remember the resolved value as the plan line cap for the rest of this turn.

## 2. Clarify only when structurally underspecified (skip by default)

Skip this step by default. Trigger it only when the request is genuinely underspecified — ambiguous scope, a system that would need to be proposed to the registry, or a real technology choice with no obvious default. Routine plans don't need clarification.

When clarification IS needed, ask the user all questions in a single `AskUserQuestion` call (where available, which is the harness's structured-question tool — options with header chips, optional previews). The tool caps at 4 questions per call — sufficient because plans are bounded at `max_plan_lines` (from `<cwd>/.x-plans/_config.lock`, default 30); needing more than 4 means the scope is too big and the request should split. Each split spec gets its own `AskUserQuestion` call. Never ask in plain prose. Do not write the plan in the same turn as the questions.

## 2a. Check for overlap with valid plans

Resolve the kebab `id:` of every system the new plan will touch via `<cwd>/.x-plans/_data_systems.yaml`. Run `x-x plans list --status valid --system <id1>,<id2>,... --overflow-keywords <terms>` where `<terms>` is a short comma-separated list of case-insensitive literal substrings chosen to discriminate *this* plan from siblings in the same systems (e.g. `webhook,retry` when several payment-system plans already exist — pick terms that further narrow the system-filtered list, not terms already implied by the systems themselves). `--system` filters server-side, so every emitted row already intersects the new plan's systems — no third-column comparison needed. `--overflow-keywords` is a no-op when the post-`--system` row count is ≤20; above that it narrows further by body substring (falling back to the latest 20 if no term matches). Pass both flags every time.

For each emitted row, ask the user — in the same single-turn questions batch from step 2 — whether the new plan **extends** or **supersedes** that plan, referenced by full slug (e.g. `00003-checkout-retry`). Find potential discrepencies between the user's ask vs. existing plans. For more accuracy, you may dig deeper by reading the overlapping plan via `<cwd>/.x-plans/<overlapping-plan-slug>.md`. Remember the answer per predecessor: a **supersedes** answer becomes a `supersedes:` entry on the new plan; an **extends** answer becomes a back-reference on the predecessor (see step 3 — you will `Edit` the predecessor's frontmatter to append the new plan's slug to its `extended_by` array).

## 2b. Research dependencies and external APIs

Before drafting tasks that reference a specific library, a third-party API, an authentication mechanism, or any external service contract, run `WebSearch` and (where the search points at upstream docs) `WebFetch` to confirm current details. Do NOT trust training-data versions or API shapes — both drift.

Mandatory when the plan touches:
- A new package/adddependency — web-search the latest stable release before pinning (AGENTS.md hard rule).
- An external service API (proxy providers, search engines, browser-automation libraries, observability backends, CDN/CI platforms, etc.).
- An authentication format (proxy URL syntax, OAuth flows, HMAC payload layouts, header conventions).
- A platform CLI (`gh`, `docker compose`, `uv`, etc.) where flags or output shape change between versions.

Cite the upstream URLs in the plan's Approach section as parenthetical `(docs: <url>)` notes so the user can audit. If research surfaces a design conflict with the user's stated intent, do not write the plan in the same turn — loop back to step 2 and clarify via `AskUserQuestion`.

## 3. Write the plan(s)

Run `x-x plans next-prefix` to obtain `<prefix>`. Pick a one-line `<title>` for the plan, then run `x-x plans slugify "<title>"` to obtain `<slug>` (do not slugify by eye — the linter compares the filename against this exact command's output). Write the plan per **Plan file contract** in `../_x-x_shared/_plan_first.md`: path `<cwd>/.x-plans/<prefix>-<slug>.md`, mandatory frontmatter in this order — `title: <title>` (first), `status: valid`, `systems: [...]`, optional `supersedes` when step 2a determined supersession, `created: <YYYY-MM-DDTHH:MM:SSZ>` (last, **UTC** — use `date -u +%Y-%m-%dT%H:%M:%SZ`).

For each predecessor the user answered **extends** in step 2a, write the link on **both** sides:
1. On the new plan, add `extends: [<pred1-slug>, <pred2-slug>, ...]` to the frontmatter (insert it right after any `supersedes:` line, before `created:`).
2. On every predecessor, `Edit` its frontmatter to append `<prefix>-<slug>` to its `extended_by:` array (create the array right before `created:` if absent).

The predecessor and the extender both stay `status: valid`. `x-x plans lint` enforces bidirectional integrity — a missing back link on either side fails the lint. Treat each predecessor `Edit` as a side effect that goes through the plan-first sub-plan protocol.

**Before drafting the `## Tasks` section, read `../_x-x_shared/_ears.md`.** It is lazy-loaded only here (kept out of step 1) to make context loading cheap; every EARS criterion names exactly one system from `<cwd>/.x-plans/_data_systems.yaml`.

The `systems:` array must list every system named in the plan's EARS tasks, each entry an exact `id:` (kebab key) from `<cwd>/.x-plans/_data_systems.yaml`. EARS criterion text still uses the corresponding display `name:` — see `../_x-x_shared/_systems.md`.

If the request covers separable scopes, you may split it into multiple specs — but only when each resulting spec's tasks target a fully disjoint set of systems. If any system would appear in two specs, keep them as one. Run `x-x plans next-prefix` once per split spec, in order, so prefixes stay sequential. Do not split for the sake of splitting.

### Hard rules

- Under `max_plan_lines` total (resolved in Step 1 from `<cwd>/.x-plans/_config.lock`; default 30). Drafts that exceed the cap will fail `x-x plans lint`.
- Sections only, in this order:
  - `## Goal` — one paragraph.
  - `## Approach` — bullets only, no prose paragraphs.
  - `## Tasks` — EARS format per `../_x-x_shared/_ears.md`.
- **Approach is design narrative; Tasks are deliverables.** Approach describes architecture, technology choices, file layout, mirrored references, etc. Tasks are the units `/x-x` flips. If Approach names a concrete artifact — a file, endpoint, doc, config row, workflow, dependency add — there MUST be at least one EARS task on the same system that makes the artifact's existence (or behavior) observable. Tasks may exist without a covering Approach bullet (that's fine; not every mechanical criterion needs design narrative). Approach bullets without a covering Task are a planning gap — the bullet's deliverable will not be tracked or written. Exception: project-level meta edits (`AGENTS.md`, `<cwd>/.x-plans/_data_systems.yaml`, per-agent config files like `.claude/settings.json` / `.codex/hooks.json`, etc.) have no system as their actor and may live in Approach alone — they have no covering Task.
- No "Considerations", "Risks", "Out of Scope", "Future Work", "Background", or preamble.
- Do not restate the user's request.
