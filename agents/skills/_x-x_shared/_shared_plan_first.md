<!-- SPDX-License-Identifier: Apache-2.0 -->

# Plan-first protocol for write skills

Every skill/tool that has side effects — creating, updating, removing, git committing, git pushing, modifying a PR, or deleting specs/tasks/systems — MUST present a plan to the user and obtain explicit approval before calling that tool. This file defines the universal protocol.

## The protocol

0. **Load the context.** Read `CLAUDE.md`, `AGENTS.md` or `GEMINI.md` first. Take that as your constitution. 
1. **Gather inputs.** Receive inputs from the user, identify the intent, find related content. No state changes yet.
2. **Build the plan.** Compose the full set of changes you intend to make.
3. **Present the plan.** Output a clear plan to the user using the template below. End with the literal sentence:
   > Reply `yes` to proceed, or tell me what to change.
4. **Wait for approval.** Wait until the user replies. A reply of `yes`, `y`, `ok`, `proceed`, `go`, `confirm`, or "approved" is approval. Anything else is a request to revise — go back to step 2 with the user's feedback.
5. **Execute.** Now execute what the user wanted. After each command, report what happened in one line.
6. **Summarize.** When done, give a one-line confirmation per entity created/changed/deleted.

## Plan template

The exact structure depends on the skill, but every plan must include:

- **Goal:** one-sentence description of the outcome.
- **Inputs already gathered:** what the skill found (spec ID, current state, related items).
- **Changes proposed:** every file that will be created/modified/deleted; every DB row that will change.
- **Named systems used or proposed:** which entries from `.x-plan/_data_systems.yaml`'s `systems` array each criterion targets, and any new systems that will be added (with `name` and `brief`).
- **EARS criteria:** the full text of each acceptance criterion in EARS form, exactly as it will be written.
- **Commands to run:** the exact shell commands or tool calls, in order.

## Context to load

Any planning or execution skill must read the following before doing anything else:

- The constitution file: whichever of `CLAUDE.md`, `AGENTS.md`, or `GEMINI.md` exists at the repo root. This sets project-wide rules and overrides defaults.
- `.x-plan/_data_systems.yaml` — registry of named systems (id, name, brief).
- `.claude/skills/_x-x_shared/_shared_systems.md` — systems-registry consultation and source-of-truth rules.

`.claude/skills/_x-x_shared/_shared_ears.md` is **lazy-loaded** — only read it when actually about to draft `## Tasks` criteria. Skills that don't author tasks (e.g., `/x-x` execution) skip it entirely.

If any of these required files is missing, STOP and report which file(s) are missing. Do not proceed.

## Plan file contract

Every plan lives at `.x-plan/<prefix>-<slug>.md` where:

- `<prefix>` is a zero-padded numeric prefix returned by `x-x plan next-prefix`. The current width is set by `prefix_width` in `.x-plan/_config.lock` (seeded by `x-x init`; defaults to 5).
- `<slug>` is a kebab-case summary of the plan's intent.

Every plan starts with YAML frontmatter:

```yaml
---
status: valid
systems: [Checkout Service, Payment Audit Log]
# Optional. Add only when this plan supersedes one or more valid plans.
supersedes: [00003-some-slug, 00007-another-slug]
---
```

Frontmatter rules:

- `status` (mandatory): one of `valid`, `superseded`, or `deprecated`. New plans always start as `valid`.
- `systems` (mandatory): inline YAML array listing every system named in the plan's EARS tasks. Each entry must be an exact `name` from `.x-plan/_data_systems.yaml`.
- `supersedes` (optional): inline YAML array of full slugs (`<prefix>-<slug>`) that this plan replaces. `/x-x` flips each listed plan's status to `superseded` after this plan finishes.

Body sections, in this order:

- `## Goal` — one paragraph stating the outcome.
- `## Approach` — bullets only, no prose paragraphs.
- `## Tasks` — EARS-format checkbox criteria per `_shared_ears.md`. `[ ]` is open, `[x]` is done. `/x-x` flips checkboxes as it executes; the source of truth for "what is true now" is the union of `[x]` criteria across `status: valid` plans.

## Plan tooling

One Go command and two Python scripts:

- `x-x plan next-prefix` — prints the next unused zero-padded prefix from `./.x-plan`. Takes no arguments. Width is read from `.x-plan/_config.lock` (`prefix_width`) and falls back to `5` when the lock file is missing.
- `x-x plan list [--status NAME[,NAME...]] [--system NAME]` — lists plans in `./.x-plan`, one tab-separated row per plan: `<slug>\t<status>\t<system>,<system>,...`. Sorted by numerical prefix. Filters:
  - `--status` keeps only matching statuses. Repeatable; comma-separated values OK.
  - `--system` keeps only plans whose `systems:` array contains the given name. Repeatable; OR semantics.
- `x-x plan lint` — validates every plan file in `./.x-plan` against the contract: filename pattern, line cap (`max_plan_lines`), frontmatter, status values, registry membership, supersedes resolution, required sections, EARS-subject ↔ `systems:` equality. Exit 0 = all pass, exit 1 = at least one failure. Findings go to stdout, one per line, prefixed with the file path; the `<ok>/<failed>` summary goes to stderr.

All three Go commands read width/line-cap from `.x-plan/_config.lock` (seeded by `x-x init`). Files with missing or malformed frontmatter trigger stderr warnings in `x-x plan list` and are reported as findings by `x-x plan lint`.

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
- 2 existing plans touch payments (.x-plan/payments-onboard.md, .x-plan/refund-window.md).
- The "Checkout Service" entry in .x-plan/_data_systems.yaml matches.

**Named systems:** Checkout Service (existing).

**Changes proposed:**
- Create .x-plan/payment-retry-policy.md.

**EARS criteria (3):**
1. When a payment authorization is declined with a transient code, the Checkout Service shall retry the authorization up to 3 times with exponential backoff.
2. While the merchant has retries disabled in their settings, the Checkout Service shall return the original decline response without retrying.
3. If the third retry is also declined, then the Checkout Service shall record the failure in the payment audit log and notify the merchant via webhook.

**Commands to run:**
1. Write .x-plan/payment-retry-policy.md with the contents above.

Reply `yes` to proceed, or tell me what to change.
```

Keep it terse. The user reads the plan, says yes, and the skill runs.
