<!-- SPDX-License-Identifier: Apache-2.0 -->

# Plan-first protocol for write skills

Every skill/tool that has side effects — creating, updating, removing, git committing/pushing, modifying a pull request, or deleting specs/tasks/systems — MUST present a plan to the user and obtain explicit approval before calling that tool. This file defines the universal protocol.

## The protocol

0. **Load the context.** Read `CLAUDE.md`, `AGENTS.md` or `GEMINI.md` first. Take that as your constitution. 
1. **Gather inputs.** Receive inputs from the user, identify the intent, find related content. No state changes yet.
2. **Build the plan.** Compose the full set of changes you intend to make.
3. **Present the plan.** Output a clear plan to the user using the template below. End with the literal sentence:
   > Reply `yes` to proceed, or tell me what to change.
4. **Wait for approval.** Wait until the user replies. A reply of `yes`, `y`, `ok`, `proceed`, `go`, `confirm`, or `approved` is approval. Anything else is a request to revise — go back to step 2 with the user's feedback.
5. **Execute.** Now execute what the user wanted. After each command, report what happened in one line.
6. **Summarize.** When done, give a one-line confirmation per entity created/changed/deleted.

## Plan template

The exact structure depends on the skill, but every plan must include:

- **Goal:** one-sentence description of the outcome.
- **Inputs already gathered:** what the skill found (spec ID, current state, related items).
- **Changes proposed:** every file that will be created/modified/deleted; every DB row that will change.
- **Named systems used or proposed:** which entries from `<cwd>/.x-plans/_data_systems.yaml`'s `systems` array each criterion targets, and any new systems that will be added (with `name` and `brief`).
- **EARS criteria:** the full text of each acceptance criterion in EARS form, exactly as it will be written.
- **Commands to run:** the exact shell commands or tool calls, in order.

## Context to load

Any planning or execution skill must read the following before doing anything else:

- `<cwd>/.x-plans/_data_systems.yaml` — registry of named systems (id, name, brief).
- `../_x-x_shared/_systems.md` — systems-registry consultation and source-of-truth rules.

`../_x-x_shared/_ears.md` is **lazy-loaded** — only read it when actually about to draft `## Tasks` criteria. Skills that don't author tasks (e.g., `/x-x` execution) skip it entirely.

If any of these required files is missing, STOP and report which file(s) are missing. Do not proceed.

The constitution file: whichever of `CLAUDE.md`, `AGENTS.md`, or `GEMINI.md` exists at the repo root. This sets project-wide rules and overrides defaults. Strongly suggest the user to have one of these if they are missing as a helpful tip.

## Plan file contract

Every plan lives at `<cwd>/.x-plans/<prefix>-<slug>.md` where:

- `<prefix>` is a zero-padded numeric prefix returned by `x-x plans next-prefix`. The current width is set by `prefix_width` in `<cwd>/.x-plans/_config.lock` (seeded by `x-x init`; defaults to 4).
- `<slug>` is a kebab-case summary of the plan's intent.

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
- `systems` (mandatory): inline YAML array listing every system named in the plan's EARS tasks. Each entry must be an exact `id:` (kebab-case key) from `<cwd>/.x-plans/_data_systems.yaml`. The corresponding display `name:` renders inside EARS criterion text as `the <name>` — see `../_x-x_shared/_systems.md`.
- `supersedes` (optional, lives on the **successor**): inline YAML array of full slugs (`<prefix>-<slug>`) that this plan replaces. `/x-x` flips each listed predecessor's status to `superseded` and appends this plan's slug to its `superseded_by:` array after this plan finishes.
- `superseded_by` (optional, lives on the **predecessor**): inline YAML array of full slugs of newer plans that have replaced this one. Maintained by `/x-x` at the same time it flips `status: valid → superseded`. Back link to `supersedes:`.
- `extends` (optional, lives on the **extender**): inline YAML array of full slugs of predecessor plans this one extends. Both predecessor and extender stay `status: valid` — `extends` is a forward pointer, not a state change.
- `extended_by` (optional, lives on the **predecessor**): inline YAML array of full slugs of newer plans that extend this one. The back link to `extends:`. `x-plan` maintains both sides whenever the user answers "extends" in step 2a.

`x-x plans lint` enforces, for **both** forward/back pairs (`supersedes`↔`superseded_by`, `extends`↔`extended_by`): every slug resolves to a sibling plan; self-references are rejected; every forward link has a matching back link and vice versa.
- `created` (mandatory, **last** key): the ISO 8601 **UTC** timestamp when the plan was authored, `YYYY-MM-DDTHH:MM:SSZ`. Filesystem timestamps don't survive git, so this is the only durable creation marker — seconds-resolution UTC keeps plans authored on the same day in deterministic order across contributors in different timezones.

Body sections, in this order:

- `## Goal` — one paragraph stating the outcome.
- `## Approach` — bullets only, no prose paragraphs.
- `## Tasks` — EARS-format checkbox criteria per `../_x-x_shared/_ears.md`. `[ ]` is open, `[x]` is done. `/x-x` flips checkboxes as it executes; the source of truth for "what is true now" is the union of `[x]` criteria across `status: valid` plans.

## Plan tooling

Four Go subcommands under `x-x plans`:

- `x-x plans next-prefix` — prints the next unused zero-padded prefix from `<cwd>/.x-plans`. Takes no arguments. Width is read from `<cwd>/.x-plans/_config.lock` (`prefix_width`) and falls back to `4` when the lock file is missing.
- `x-x plans list [--status NAME[,NAME...]] [--system ID] [--order asc|desc] [--overflow-keywords PATTERN[,PATTERN...]]` — lists plans in `<cwd>/.x-plans`, one tab-separated row per plan: `<slug>\t<status>\t<id>,<id>,...`.
  - `--status` keeps only matching statuses. Repeatable; comma-separated values OK.
  - `--system` keeps only plans whose `systems:` array contains the given kebab id (the `id:` key from `_data_systems.yaml`). Repeatable; OR semantics.
  - `--order` sorts by zero-padded prefix; default `desc` (latest first). Pass `--order=asc` when you need oldest-first execution order (e.g. `/x-x` work-queue and ground-truth lookup).
  - `--overflow-keywords` accepts one or more case-insensitive literal substrings and engages only when the post-filter row count exceeds the project's overflow threshold (default 20). Matches against plan **body** only; on overflow with no match, returns the top-threshold rows as a fallback. Always safe to pass — it's a no-op below the threshold.
- `x-x plans lint` — validates every plan file in `<cwd>/.x-plans` against the contract: filename pattern, line cap (`max_plan_lines`), frontmatter (including `title:` first / `created:` last), status values, registry membership, supersedes resolution, `created:` shape, filename-slug ↔ `slugify(title)` equality, required sections, EARS-subject ↔ `systems:` equality. Exit 0 = all pass, exit 1 = at least one failure. Findings go to stdout, one per line, prefixed with the file path; the `<ok>/<failed>` summary goes to stderr.
- `x-x plans slugify "<title>"` — prints the kebab-case slug for the given title. Use it to derive the post-prefix portion of new plan filenames so author and lint agree on the same algorithm.

All Go commands except `slugify` read width/line-cap from `<cwd>/.x-plans/_config.lock` (seeded by `x-x init`). Files with missing or malformed frontmatter trigger stderr warnings in `x-x plans list` and are reported as findings by `x-x plans lint`.

## Approval discipline

- A single `yes` approves the entire plan as presented. If the user asks for a change ("rename the title", "drop criterion 3"), revise and re-present — the previous approval does not carry forward.
- Approval covers only the commands listed in the plan. Anything that emerges mid-execution (e.g. a contradiction surfaces and you want to update another spec) requires its own plan and its own approval.
- Never bypass this protocol because the change "seems small" or "is just a rename". Side effects are side effects.

## What the user sees

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
