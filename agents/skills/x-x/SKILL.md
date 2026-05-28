---
# SPDX-License-Identifier: Apache-2.0
name: x-x
description: Execute plans in .x-plans/ sequentially by numerical prefix. Reads each plan, works through its EARS-format tasks, marks checkboxes complete, and stops on the first task it cannot finish. Fans out to git worktrees when consecutive plans declare disjoint systems.
---

# x-x

## 0. Announce review mode (non-blocking)

Before announcing, read `.x-plans/_config.lock` and extract `review_per` (string). If the lock file is missing, STOP and tell the user this directory isn't set up for x-x yet — they need to run `x-x init`. If the file exists but the key is absent or set to anything other than `task`/`plan`, default to `task`. Remember the resolved mode as the **active review mode** for this run.

Emit exactly one line that matches the resolved mode — then immediately proceed to Step 1 without waiting:

- If active mode is `task`:
  > FYI: I'll review each task with you. If you'd rather approve one plan at a time, say "review per plan."
- If active mode is `plan`:
  > FYI: I'll review the whole plan with you at once. If you'd rather approve one task at a time, say "review per task."

The user may switch modes at any point ("review per plan" / "review per task"); apply at the next approval boundary, never retroactively. A mid-run switch lasts only for the remainder of this run.

## 1. Load context

Required reads before doing anything else:

- `<cwd>/.x-plans/_data_systems.yaml` — registry of named systems (id, name, brief). If missing, STOP and tell the user this directory isn't set up for x-x yet — they need to run `x-x init`.
- The project constitution: whichever of `CLAUDE.md`, `AGENTS.md`, or `GEMINI.md` exists at the repo root. Read whichever is present and take it as the override on all defaults in this skill. If none exist, suggest the user create one as a helpful tip and proceed.

The plan-first protocol (used by Step 3.3.2 when presenting sub-plans) is defined inline in Appendix A at the bottom of this file. Read it before the first approval prompt.

## 2. Enumerate plans

Run `x-x plans list --status valid --order=asc`. Output is tab-separated, one row per plan, sorted by numerical prefix ascending (the default sort is descending; `--order=asc` gives the oldest-first execution order this skill iterates):

```
<slug>\t<status>\t<id>,<id>,...
```

All emitted rows are the work queue — the `--status valid` flag filters out `superseded` and `deprecated`. Files in `.x-plans/` that match `<prefix>-<slug>.md` but have missing or malformed frontmatter trigger stderr warnings from the script; flag those in your end-of-run summary so they aren't lost.

The third column is each plan's **scope** — the kebab `id:` of every system it touches, as declared in `<cwd>/.x-plans/_data_systems.yaml`.

## 2a. Progress tracking

Always maintain a visible task list during execution. After enumeration, create one `TaskCreate` task per plan in the work queue (subject = plan slug, description = its scope). Mark each task `in_progress` when you start the plan's first incomplete EARS task and `completed` when the plan's last task is `[x]`. In parallel mode, give each worktree-bound plan its own task. Keep the list in sync with reality — every status change reflects an actual execution event.

If the user enqueues new work mid-execution — a new plan dropped into `.x-plans/`, a new `[ ]` EARS criterion added to a running plan, or an out-of-band request — append it via `TaskCreate` immediately so the visible queue stays complete. Never absorb new work silently. Prioritization (interrupt vs. queue-at-end) follows the user's instruction; default is queue-at-end unless they signal otherwise.

## 3. Sequential mode (default)

For each plan, in numerical order:

1. Read the plan in full.
2. If every `## Tasks` checkbox is already `[x]`, report the plan as done and move on.
3. For each incomplete `[ ]` task, in the order written:
   1. Compose the side effects required to satisfy the task.
   2. Approval, per the active review mode resolved in Step 0:
      - **Per-task:** present a sub-plan for this task per the plan-first protocol in Appendix A and wait for `yes`.
      - **Per-plan:** on the first incomplete task of the plan, present **one** consolidated sub-plan (per Appendix A) listing every incomplete `[ ]` task in this plan and all their side effects; wait for a single `yes`. For subsequent tasks in the same plan, skip the prompt — the bundle approval covers them. A verification failure (step 3.3.4) halts the plan per Step 6; bundle approval does not survive a failed task.
   3. Execute. After each command, report what happened in one line.
   4. **Verify before flipping.** If the task added new code paths (endpoint, worker, parser, adapter, signal handler, etc.), write at least one unit or smoke test exercising the new path in the project's test layout. Then run the project's standard test + lint + type-check target, if exists. They MUST exit 0 before the checkbox flips. If verification fails, leave the checkbox `[ ]` and apply the failure-mode protocol in step 6. Pure config / doc / registry / settings edits skip the test-write step but still run lint + type-checks.
   5. Flip the checkbox from `[ ]` to `[x]` in the plan file.
4. After all tasks in the plan are `[x]`:
   1. If the plan's frontmatter includes `supersedes: [<slug>, ...]`, for each listed predecessor: `Edit` its plan file to (a) flip `status: valid` → `status: superseded`, and (b) append this plan's slug to its `superseded_by:` array (create the array right before `created:` if absent). Both edits must land in the same revision — `x-x plans lint` enforces that the supersedes ↔ superseded_by back link is symmetric. Treat each predecessor `Edit` as a side effect that goes through the plan-first sub-plan protocol.
   2. Report one-line completion and move to the next plan.

## 4. Parallel mode (auto-detected)

If the next contiguous run of upcoming plans declares pairwise disjoint scopes (zero shared systems across them), propose fanning out to git worktrees.

On approval, for each plan in the parallel run:

1. Create a worktree off the current HEAD:
   `git worktree add ../<repo>.worktrees/<prefix>-<slug> -b plan/<prefix>-<slug>`
   where `<repo>` is the basename of the current repo directory.
2. Execute the plan inside its own worktree following the sequential rules above (sub-plans included).
3. On completion, leave the worktree intact and report the worktree path + branch.

Do not merge worktrees back, do not remove them, and do not modify any branch outside its own worktree. Cleanup and merge are the user's call.

## 5. Ground-truth lookup

When a task needs the current contract for a system (to extend, modify, or reason about existing behavior), run `x-x plans list --status valid --system <id> --order=asc` (the kebab `id:` from `<cwd>/.x-plans/_data_systems.yaml`, not the display name), then read the listed plan files. Collect only `[x]` (completed) criteria naming that system, ordered by numerical prefix ascending. Treat that ordered list as the live contract. Never read `superseded` or `deprecated` plans for current truth — they are history.

## 6. Failure mode

If a task cannot be completed (command fails, user rejects the sub-plan, missing input), STOP that worktree's sequence and leave the checkbox `[ ]`. In sequential mode this halts everything. In parallel mode, sibling worktrees continue independently. At the end, report every blocking plan + task in one summary. No auto-merge, no auto-cleanup, no skipping past failures.

## Appendix A: Plan-first protocol

Every sub-plan presented for approval in Step 3.3.2 follows this protocol. The same protocol is used by the `x-plan` skill when authoring full plan files; here in `x-x` it governs the approval prompts shown for each task (per-task) or each plan (per-plan).

### The protocol

0. **Load the context.** Already done in Step 1 — the constitution file and the systems registry are required reads.
1. **Gather inputs.** Receive inputs from the user, identify the intent, find related content. No state changes yet.
2. **Build the plan.** Compose the full set of changes you intend to make.
3. **Present the plan.** Output a clear plan to the user using the template below. End with the literal sentence:
   > Reply `yes` to proceed, or tell me what to change.
4. **Wait for approval.** Wait until the user replies. A reply of `yes`, `y`, `ok`, `proceed`, `go`, `confirm`, or `approved` is approval. Anything else is a request to revise — go back to step 2 with the user's feedback.
5. **Execute.** Now execute what the user wanted. After each command, report what happened in one line.
6. **Summarize.** When done, give a one-line confirmation per entity created/changed/deleted.

### Sub-plan template

Every sub-plan must include:

- **Goal:** one-sentence description of the outcome.
- **Inputs already gathered:** what the skill found (plan slug, current state, related items).
- **Changes proposed:** every file that will be created/modified/deleted; every DB row that will change.
- **Named systems used:** which entries from `<cwd>/.x-plans/_data_systems.yaml`'s `systems` array the work targets.
- **Commands to run:** the exact shell commands or tool calls, in order.

### Plan file format (read-side, for executing plan files written by x-plan)

Every plan file under `<cwd>/.x-plans/` lives at `<prefix>-<slug>.md` with YAML frontmatter:

```yaml
---
title: <one-line human-readable title>
status: valid | superseded | deprecated
systems: [system-id-1, system-id-2]
# Optional: forward link from successor to each predecessor it replaces.
supersedes: [00003-some-slug, 00007-another-slug]
# Optional: back link on the predecessor; mirrors every `supersedes:` that names it.
superseded_by: [00021-some-slug]
# Optional: forward link from extender to each predecessor it extends.
extends: [00002-some-slug]
# Optional: back link on the predecessor; mirrors every `extends:` that names it.
extended_by: [00012-some-slug, 00015-another-slug]
created: 2026-05-23T14:30:00Z
---
```

Body sections, in order: `## Goal`, `## Approach`, `## Tasks` (EARS-format checkboxes; `[ ]` open, `[x]` done — x-x flips these as it executes).

### Plan tooling (the `x-x plans` subcommands)

- `x-x plans list [--status NAME[,NAME...]] [--system ID] [--order asc|desc] [--overflow-keywords PATTERN[,PATTERN...]]` — lists plans, one tab-separated row per plan: `<slug>\t<status>\t<id>,<id>,...`.
  - `--status` keeps only matching statuses. Repeatable; comma-separated values OK.
  - `--system` keeps only plans whose `systems:` array contains the given kebab id.
  - `--order` sorts by zero-padded prefix; default `desc`. Pass `--order=asc` when you need oldest-first execution order (this skill's work queue uses asc).
  - `--overflow-keywords` filters by body substring when row count exceeds the project's overflow threshold. Safe to omit.
- `x-x plans lint` — validates every plan file. Exit 0 = all pass, exit 1 = at least one failure.

All `x-x plans` commands read `prefix_width` / `max_plan_lines` from `<cwd>/.x-plans/_config.lock` (seeded by `x-x init`).

### Approval discipline

- A single `yes` approves the entire sub-plan as presented. If the user asks for a change ("rename", "drop step 3"), revise and re-present — the previous approval does not carry forward.
- Approval covers only the commands listed in the sub-plan. Anything that emerges mid-execution requires its own sub-plan and its own approval.
- Never bypass this protocol because the change "seems small". Side effects are side effects.

### What the user sees

A sub-plan looks like this when rendered:

```
## Plan

**Goal:** Implement the payment retry policy task.

**Inputs gathered:**
- Plan slug 00012-payment-retry-policy, status valid.
- Checkout Service entry in _data_systems.yaml.

**Named systems:** Checkout Service.

**Changes proposed:**
- Edit src/checkout/retry.ts to add exponential-backoff retry loop.
- Add unit test test/checkout/retry.test.ts covering 3-retry cap + transient-only filter.

**Commands to run:**
1. Edit src/checkout/retry.ts.
2. Write test/checkout/retry.test.ts.
3. Run `npm test -- retry`.

Reply `yes` to proceed, or tell me what to change.
```

Keep it terse. The user reads, says yes, the task executes.
