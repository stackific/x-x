---
# SPDX-License-Identifier: Apache-2.0
name: x-plan
description: Plan-first workflow for this repo. Loads the shared planning context, then writes a tightly-scoped plan following EARS-format tasks. Invoke at the start of any planning or design task.
---

# x-plan

## 1. Load context

Required reads before doing anything else:

- `<cwd>/.x-plans/_data_systems.yaml` — registry of named systems (id, name, brief). Consultation and propose-new-system rules are in Appendix C.
- `<cwd>/.x-plans/_config.lock` — extract `max_plan_lines` (integer). If the lock file is missing, STOP and tell the user this directory isn't set up for x-x yet — they need to run `x-x init`. If the file exists but the key is absent or non-positive, fall back to `30` (matches `x-x plans lint`). Remember the resolved value as the plan line cap for the rest of this turn.
- The project constitution: whichever of `CLAUDE.md`, `AGENTS.md`, or `GEMINI.md` exists at the repo root. Read whichever is present and take it as the override on all defaults in this skill. If none exist, suggest the user create one as a helpful tip and proceed.

The plan-first protocol (full approval loop + sub-plan template) is defined in Appendix A. The EARS criteria rules referenced from Step 3's `## Tasks` are in Appendix B. The named-systems registry rules referenced from Steps 2a / 3 are in Appendix C. All three appendices are part of this SKILL.md and are already in your context — refer back to them when each step calls for them.

## 2. Clarify only when structurally underspecified (skip by default)

Skip this step by default. Trigger it only when the request is genuinely underspecified — ambiguous scope, a system that would need to be proposed to the registry, or a real technology choice with no obvious default. Routine plans don't need clarification.

When clarification IS needed, ask the user all questions in a single `AskUserQuestion` call (where available, which is the harness's structured-question tool — options with header chips, optional previews). The tool caps at 4 questions per call — sufficient because plans are bounded at `max_plan_lines` (from `<cwd>/.x-plans/_config.lock`, default 30); needing more than 4 means the scope is too big and the request should split. Each split spec gets its own `AskUserQuestion` call. Never ask in plain prose. Do not write the plan in the same turn as the questions.

## 2a. Check for overlap with valid plans

Resolve the kebab `id:` of every system the new plan will touch via `<cwd>/.x-plans/_data_systems.yaml`. Run `x-x plans list --status valid --system <id1>,<id2>,... --overflow-keywords <terms>` where `<terms>` is a short comma-separated list of case-insensitive literal substrings chosen to discriminate *this* plan from siblings in the same systems (e.g. `webhook,retry` when several payment-system plans already exist — pick terms that further narrow the system-filtered list, not terms already implied by the systems themselves). `--system` filters server-side, so every emitted row already intersects the new plan's systems — no third-column comparison needed. `--overflow-keywords` is a no-op when the post-`--system` row count is ≤20; above that it narrows further by body substring (falling back to the latest 20 if no term matches). Pass both flags every time.

For each emitted row, ask the user — in the same single-turn questions batch from step 2 — whether the new plan **extends** or **supersedes** that plan, referenced by full slug (e.g. `00003-checkout-retry`). Find potential discrepencies between the user's ask vs. existing plans. For more accuracy, you may dig deeper by reading the overlapping plan via `<cwd>/.x-plans/<overlapping-plan-slug>.md`. Remember the answer per predecessor: a **supersedes** answer becomes a `supersedes:` entry on the new plan; an **extends** answer becomes a back-reference on the predecessor (see step 3 — you will `Edit` the predecessor's frontmatter to append the new plan's slug to its `extended_by` array).

## 2b. Research dependencies and external APIs

Before drafting tasks that reference a specific library, a third-party API, an authentication mechanism, or any external service contract, run `WebSearch` and (where the search points at upstream docs) `WebFetch` to confirm current details. Do NOT trust training-data versions or API forms — both drift.

Mandatory when the plan touches:
- A new package/adddependency — web-search the latest stable release before pinning (AGENTS.md hard rule).
- An external service API (proxy providers, search engines, browser-automation libraries, observability backends, CDN/CI platforms, etc.).
- An authentication format (proxy URL syntax, OAuth flows, HMAC payload layouts, header conventions).
- A platform CLI (`gh`, `docker compose`, `uv`, etc.) where flags or output format change between versions.

Cite the upstream URLs in the plan's Approach section as parenthetical `(docs: <url>)` notes so the user can audit. If research surfaces a design conflict with the user's stated intent, do not write the plan in the same turn — loop back to step 2 and clarify via `AskUserQuestion`.

## 3. Write the plan(s)

Run `x-x plans next-prefix` to obtain `<prefix>`. Pick a one-line `<title>` for the plan, then run `x-x plans slugify "<title>"` to obtain `<slug>` (do not slugify by eye — the linter compares the filename against this exact command's output). Write the plan per the **Plan file contract** in Appendix A: path `<cwd>/.x-plans/<prefix>-<slug>.md`, mandatory frontmatter in this order — `title: <title>` (first), `status: valid`, `systems: [...]`, optional `supersedes` when step 2a determined supersession, `created: <YYYY-MM-DDTHH:MM:SSZ>` (last, **UTC** — use `date -u +%Y-%m-%dT%H:%M:%SZ`).

For each predecessor the user answered **extends** in step 2a, write the link on **both** sides:
1. On the new plan, add `extends: [<pred1-slug>, <pred2-slug>, ...]` to the frontmatter (insert it right after any `supersedes:` line, before `created:`).
2. On every predecessor, `Edit` its frontmatter to append `<prefix>-<slug>` to its `extended_by:` array (create the array right before `created:` if absent).

The predecessor and the extender both stay `status: valid`. `x-x plans lint` enforces bidirectional integrity — a missing back link on either side fails the lint. Treat each predecessor `Edit` as a side effect that goes through the plan-first sub-plan protocol.

**Before drafting the `## Tasks` section, refer to Appendix B (EARS rules).** Every EARS criterion names exactly one system from `<cwd>/.x-plans/_data_systems.yaml`.

The `systems:` array must list every system named in the plan's EARS tasks, each entry an exact `id:` (kebab key) from `<cwd>/.x-plans/_data_systems.yaml`. EARS criterion text still uses the corresponding display `name:` — see Appendix C (named-systems registry rules).

If the request covers separable scopes, you may split it into multiple specs — but only when each resulting spec's tasks target a fully disjoint set of systems. If any system would appear in two specs, keep them as one. Run `x-x plans next-prefix` once per split spec, in order, so prefixes stay sequential. Do not split for the sake of splitting.

### Hard rules

- Under `max_plan_lines` total (resolved in Step 1 from `<cwd>/.x-plans/_config.lock`; default 30). Drafts that exceed the cap will fail `x-x plans lint`.
- Sections only, in this order:
  - `## Goal` — one paragraph.
  - `## Approach` — bullets only, no prose paragraphs.
  - `## Tasks` — EARS format per Appendix B.
- **Approach is design narrative; Tasks are deliverables.** Approach describes architecture, technology choices, file layout, mirrored references, etc. Tasks are the units `/x-x` flips. If Approach names a concrete artifact — a file, endpoint, doc, config row, workflow, dependency add — there MUST be at least one EARS task on the same system that makes the artifact's existence (or behavior) observable. Tasks may exist without a covering Approach bullet (that's fine; not every mechanical criterion needs design narrative). Approach bullets without a covering Task are a planning gap — the bullet's deliverable will not be tracked or written. Exception: project-level meta edits (`AGENTS.md`, `<cwd>/.x-plans/_data_systems.yaml`, per-agent config files like `.claude/settings.json` / `.codex/hooks.json`, etc.) have no system as their actor and may live in Approach alone — they have no covering Task.
- No "Considerations", "Risks", "Out of Scope", "Future Work", "Background", or preamble.
- Do not restate the user's request.

## Appendix A: Plan-first protocol

Every plan that has side effects — creating, updating, removing, git committing/pushing, modifying a pull request, or deleting specs/tasks/systems — MUST present a plan to the user and obtain explicit approval before calling that tool. This appendix defines the protocol and the plan-file contract.

### The protocol

0. **Load the context.** Already done in Step 1 — the constitution file and the systems registry are required reads.
1. **Gather inputs.** Receive inputs from the user, identify the intent, find related content. No state changes yet.
2. **Build the plan.** Compose the full set of changes you intend to make.
3. **Present the plan.** Output a clear plan to the user using the template below. End with the literal sentence:
   > Reply `yes` to proceed, or tell me what to change.
4. **Wait for approval.** Wait until the user replies. A reply of `yes`, `y`, `ok`, `proceed`, `go`, `confirm`, or `approved` is approval. Anything else is a request to revise — go back to step 2 with the user's feedback.
5. **Execute.** Now execute what the user wanted. After each command, report what happened in one line.
6. **Summarize.** When done, give a one-line confirmation per entity created/changed/deleted.

### Plan template

The exact structure depends on the skill, but every plan must include:

- **Goal:** one-sentence description of the outcome.
- **Inputs already gathered:** what the skill found (spec ID, current state, related items).
- **Changes proposed:** every file that will be created/modified/deleted; every DB row that will change.
- **Named systems used or proposed:** which entries from `<cwd>/.x-plans/_data_systems.yaml`'s `systems` array each criterion targets, and any new systems that will be added (with `name` and `brief`).
- **EARS criteria:** the full text of each acceptance criterion in EARS form, exactly as it will be written (see Appendix B).
- **Commands to run:** the exact shell commands or tool calls, in order.

### Plan file contract

Every plan lives at `<cwd>/.x-plans/<prefix>-<slug>.md` where:

- `<prefix>` is a zero-padded numeric prefix returned by `x-x plans next-prefix`. Width comes from `prefix_width` in `<cwd>/.x-plans/_config.lock` (seeded by `x-x init`; default 4).
- `<slug>` is a kebab-case summary of the plan's intent, produced by `x-x plans slugify "<title>"`.

Every plan starts with YAML frontmatter:

```yaml
---
title: Add payment retry policy with exponential backoff for transient declines and merchant webhook on terminal failure
status: valid
systems: [checkout-service, payment-audit-log]
# Optional. Forward link from the *successor* to each predecessor it replaces.
supersedes: [00003-some-slug, 00007-another-slug]
# Optional. Back link on the *predecessor*; mirrors every `supersedes:` that names it.
superseded_by: [00021-some-slug]
# Optional. Forward link from the *extender* to each predecessor it extends.
extends: [00002-some-slug]
# Optional. Back link on the *predecessor*; mirrors every `extends:` that names it.
extended_by: [00012-some-slug, 00015-another-slug]
created: 2026-05-23T14:30:00Z
---
```

Frontmatter rules:

- `title` (mandatory, **first** key): one-line human-readable and comprehensive title. The post-prefix portion of the filename MUST equal `x-x plans slugify "<title>"`; lint enforces this.
- `status` (mandatory): one of `valid`, `superseded`, or `deprecated`. New plans always start as `valid`.
- `systems` (mandatory): inline YAML array listing every system named in the plan's EARS tasks. Each entry must be an exact `id:` (kebab-case key) from `<cwd>/.x-plans/_data_systems.yaml`. The corresponding display `name:` renders inside EARS criterion text as `the <name>` — see Appendix C.
- `supersedes` (optional, lives on the **successor**): inline YAML array of full slugs (`<prefix>-<slug>`) that this plan replaces. `/x-x` flips each listed predecessor's status to `superseded` and appends this plan's slug to its `superseded_by:` array after this plan finishes.
- `superseded_by` (optional, lives on the **predecessor**): inline YAML array of full slugs of newer plans that have replaced this one. Maintained by `/x-x` at the same time it flips `status: valid → superseded`. Back link to `supersedes:`.
- `extends` (optional, lives on the **extender**): inline YAML array of full slugs of predecessor plans this one extends. Both predecessor and extender stay `status: valid` — `extends` is a forward pointer, not a state change.
- `extended_by` (optional, lives on the **predecessor**): inline YAML array of full slugs of newer plans that extend this one. The back link to `extends:`. `x-plan` maintains both sides whenever the user answers "extends" in step 2a.
- `created` (mandatory, **last** key): the ISO 8601 **UTC** timestamp when the plan was authored, `YYYY-MM-DDTHH:MM:SSZ`. Filesystem timestamps don't survive git, so this is the only durable creation marker — seconds-resolution UTC keeps plans authored on the same day in deterministic order across contributors in different timezones.

`x-x plans lint` enforces, for **both** forward/back pairs (`supersedes`↔`superseded_by`, `extends`↔`extended_by`): every slug resolves to a sibling plan; self-references are rejected; every forward link has a matching back link and vice versa.

Body sections, in this order:

- `## Goal` — one paragraph stating the outcome.
- `## Approach` — bullets only, no prose paragraphs.
- `## Tasks` — EARS-format checkbox criteria per Appendix B. `[ ]` is open, `[x]` is done. `/x-x` flips checkboxes as it executes; the source of truth for "what is true now" is the union of `[x]` criteria across `status: valid` plans.

### Plan tooling

Four Go subcommands under `x-x plans`:

- `x-x plans next-prefix` — prints the next unused zero-padded prefix from `<cwd>/.x-plans`. Takes no arguments. Width is read from `<cwd>/.x-plans/_config.lock` (`prefix_width`) and falls back to `4` when the lock file is missing.
- `x-x plans list [--status NAME[,NAME...]] [--system ID] [--order asc|desc] [--overflow-keywords PATTERN[,PATTERN...]]` — lists plans in `<cwd>/.x-plans`, one tab-separated row per plan: `<slug>\t<status>\t<id>,<id>,...`.
  - `--status` keeps only matching statuses. Repeatable; comma-separated values OK.
  - `--system` keeps only plans whose `systems:` array contains the given kebab id (the `id:` key from `_data_systems.yaml`). Repeatable; OR semantics.
  - `--order` sorts by zero-padded prefix; default `desc` (latest first). Pass `--order=asc` when you need oldest-first execution order (e.g. `/x-x` work-queue and ground-truth lookup).
  - `--overflow-keywords` accepts one or more case-insensitive literal substrings and engages only when the post-filter row count exceeds the project's overflow threshold (default 20). Matches against plan **body** only; on overflow with no match, returns the top-threshold rows as a fallback. Always safe to pass — it's a no-op below the threshold.
- `x-x plans lint` — validates every plan file in `<cwd>/.x-plans` against the contract: filename pattern, line cap (`max_plan_lines`), frontmatter (including `title:` first / `created:` last), status values, registry membership, supersedes resolution, `created:` format, filename-slug ↔ `slugify(title)` equality, required sections, EARS-subject ↔ `systems:` equality. Exit 0 = all pass, exit 1 = at least one failure. Findings go to stdout, one per line, prefixed with the file path; the `<ok>/<failed>` summary goes to stderr.
- `x-x plans slugify "<title>"` — prints the kebab-case slug for the given title. Use it to derive the post-prefix portion of new plan filenames so author and lint agree on the same algorithm.

All Go commands except `slugify` read width/line-cap from `<cwd>/.x-plans/_config.lock` (seeded by `x-x init`). Files with missing or malformed frontmatter trigger stderr warnings in `x-x plans list` and are reported as findings by `x-x plans lint`.

### Approval discipline

- A single `yes` approves the entire plan as presented. If the user asks for a change ("rename the title", "drop criterion 3"), revise and re-present — the previous approval does not carry forward.
- Approval covers only the commands listed in the plan. Anything that emerges mid-execution (e.g. a contradiction surfaces and you want to update another spec) requires its own plan and its own approval.
- Never bypass this protocol because the change "seems small" or "is just a rename". Side effects are side effects.

### What the user sees

A plan looks like this when rendered:

```
## Plan

**Goal:** Add a plan for the new payment retry policy.

**Inputs gathered:**
- 2 existing plans touch payments (.x-plans/payments-onboard.md, .x-plans/refund-window.md).
- The "Checkout Service" entry in .x-plans/_data_systems.yaml matches.

**Named systems:** Checkout Service (existing).

**Changes proposed:**
- Create .x-plans/payment-retry-policy.md.

**EARS criteria (3):**
1. When a payment authorization is declined with a transient code, the Checkout Service shall retry the authorization up to 3 times with exponential backoff.
2. While the merchant has retries disabled in their settings, the Checkout Service shall return the original decline response without retrying.
3. If the third retry is also declined, then the Checkout Service shall record the failure in the payment audit log and notify the merchant via webhook.

**Commands to run:**
1. Write .x-plans/payment-retry-policy.md with the contents above.

Reply `yes` to proceed, or tell me what to change.
```

Keep it terse. The user reads the plan, says yes, and the skill runs.

## Appendix B: EARS — acceptance criteria language

Every `## Tasks` checkbox is an EARS criterion. Follow these rules without exception.

### The 5 patterns

| # | Pattern | When to use | Template |
|---|---------|-------------|----------|
| 1 | Ubiquitous | Always true | `The <system> shall <response>.` |
| 2 | State-driven | A state must hold | `While <precondition>, the <system> shall <response>.` |
| 3 | Event-driven | A discrete event triggers it | `When <trigger>, the <system> shall <response>.` |
| 4 | Optional feature | Only in certain configurations | `Where <feature is included>, the <system> shall <response>.` |
| 5 | Unwanted behavior | A failure or misuse case | `If <unwanted trigger>, then the <system> shall <response>.` |

Complex requirements stack `While` with `When` OR `If ... then` (not both), in fixed order. `Where` is standalone — never stacks.

Example of a stacked complex requirement:
`While the aircraft is on ground, when reverse thrust is commanded, the engine control system shall enable reverse thrust.`

### Hard rules

1. **Exactly one named system per criterion.** The system is a concrete subsystem, service, or component from the registry (`<cwd>/.x-plans/_data_systems.yaml`) — never bare `the system`, `it`, `the app`, `the service`, `the application`, `the platform`. See Appendix C for registry consultation and propose-new-system rules.
2. **Use `shall`** for the response. Never `should`, `may`, `might`, `will`, `can`, `must`.
3. **One requirement per sentence.** Split bundled inputs.
4. **`When` and `If` are mutually exclusive** in one sentence — `When` is expected, `If ... then` is unwanted.
5. **Use exact keywords** (`While`, `When`, `If ... then`, `Where`, `shall`) in the fixed slot order: `[While ...,] [When ..., | If ..., then] the <system> shall <response>.`
6. **Response must be concrete and observable.** No "feel premium", "look modern", etc. If non-functional without a measurable target, refuse and ask.

If you can't satisfy these, refuse and ask one direct question per gap. No padding, no hedging.

### Output format

Each criterion is a checkbox in `## Tasks`. `[ ]` is open, `[x]` is done — `/x-x` flips them as it executes.

```
- [ ] The Checkout Service shall <response>.
- [ ] When the Kanban Board UI receives a drop event, the Kanban Board UI shall <response>.
```

If clarifying questions are needed, ask them as a numbered list and stop. Do not produce partial requirements.

## Appendix C: Named systems — registry and matching

Every EARS criterion names exactly one system (the actor that performs the response). To stay consistent across specs and tasks, this project keeps a project-level registry of named systems at `<cwd>/.x-plans/_data_systems.yaml`.

### What an entry looks like

Each entry has three fields:

- `name` — the free-text human label rendered in EARS criteria as `the <name>`. Use natural capitalization and spacing. Examples: `"Checkout Service"`, `"Kanban Board UI"`, `"Spec Sync Engine"`.
- `id` — the URL-safe key derived from `name`. Lowercase letters/digits/hyphens only. Never write the slug into criterion text.
- `brief` — one short sentence describing what the system does and the boundary it owns.

A typical `<cwd>/.x-plans/_data_systems.yaml` should read:

```
systems:
  - id: dashed-slug1
    name: Human Readable Service Name
    brief: A summary of the service.
  - id: dashed-slug2
    name: Human Friendly Name
    brief: A summary of the service.
```

### Naming rules (you must enforce)

1. **Allowed characters**: letters, digits, spaces, and hyphens only. Underscores, commas, and other punctuation are rejected. Underscores are SQL `LIKE` wildcards (the reference-count query would mismatch); commas conflict with EARS clause separators (a name with a comma would make `When X, the Y, Z shall …` ambiguous).
2. **Must contain at least one letter**. Names made up of only digits, spaces, or hyphens (e.g. `"123"`, `"42-09"`) aren't legible system names. `"v2 Gateway"` is fine because it has `v`/`G`/etc; `"42"` alone is not.
3. **No leading "the"**: the name must not start with the word `the` (case-insensitive). EARS already prepends `the <name>` to every criterion, so a name like `"The Service"` would render as `"the The Service shall …"` — refused at validation time.
4. **Length cap**: 60 characters. Long enough for "iOS Push Notification Client" but not for a paragraph.
5. **Slug uniqueness**: two display names that slugify to the same key (e.g. `"Checkout Service"` and `"Checkout  Service"` with extra spaces) collide. The user must rename one before both can coexist.
6. **Brief**: 1–240 characters, single sentence preferred.

### How to consult the registry

Read `<cwd>/.x-plans/_data_systems.yaml` directly and update it as needed.

For each spec or task you intend to write:
1. Identify the actor — the specific component, service, or device that performs the response.
2. Try to match it against an existing entry by name AND `brief`.
3. If matched: use the existing entry's `name` verbatim in the EARS criterion text (e.g., "the Checkout Service shall …") AND its `id` verbatim in the plan's frontmatter `systems:` array (e.g., `systems: [checkout-service]`). These two are always taken from the same registry entry.
4. If not matched: STOP. Propose a new system to the user (id + name + one-sentence brief). On approval, add that to `<cwd>/.x-plans/_data_systems.yaml`. Then continue.

### Source of truth

A system's current contract is the set of `[x]` EARS criteria across plans whose frontmatter is `status: valid` AND whose `systems:` array includes the system's id. Use `x-x plans list --status valid --system <id> --order=asc` to enumerate them in chronological order, then read each plan's `## Tasks` for `[x]` criteria naming the system. Plans with `status: superseded` or `status: deprecated` are history and must never be read for current truth.

### When the registry is empty

A fresh project may have an empty `systems` YAML. Do not try to write criteria with bare `the system` because the registry is empty — propose a real system to the user instead.

### When more than one entry is plausible

Pick the most specific match. If two entries genuinely apply (e.g. a frontend component and a backend service both behave on the same trigger), split the criterion into two: one per system. EARS forbids more than one named system per criterion.

### When you propose a new system

Use natural English. Briefs should answer "what does this system do, and what's its boundary?" in 10–25 words.

Try to be one level more granular when choosing a system name: if you choose the root API project as the system, most of the plans/tasks will be around that. But if you choose a module inside of the API project, you could generate more specific plans/tasks specifically targeted to that module. You can still use the API project, but choose it for more umbrella-level activities (logging, configuration, compliance, etc.).

A few do-and-don't examples:

| ✅ Good | ❌ Bad | Why |
|---------|--------|-----|
| `"Checkout Service"` | `"checkout_service"` | Underscores aren't allowed; use natural spaces. |
| `"Kanban Board UI"` | `"kanban-board-ui"` | Present the human label, not the slug. |
| `"Order Audit Log"` | `"The Order Audit Log"` | Names must not start with "the". |
| `"iOS Push Client"` | `"iOS Push! Client"` | `!` isn't an allowed character. |
| `"Order Auth Service"` | `"Order, Auth Service"` | Commas conflict with EARS clause separators. |
| `"v2 Gateway"` | `"123"` or `"42-09"` | Name must contain at least one letter. |

### What you must never do

- Never invent a system name on the fly that's not in the registry. Either match an entry or propose one and wait for approval.
- Never write `the system shall …`, `it shall …`, `the application shall …`, `the service shall …`, `the platform shall …`. Those are banned per EARS.
- Never write the slug/id into EARS criterion text. EARS uses the display name (`"the Checkout Service shall …"`); the id is for the plan's frontmatter `systems:` array and `--system <id>` lookups only.
