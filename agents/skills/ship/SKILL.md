---
# SPDX-License-Identifier: Apache-2.0
name: ship
description: Execute plans in .stax/ sequentially by numerical prefix. Reads each plan, works through its EARS-format tasks, marks checkboxes complete, and stops on the first task it cannot finish. Fans out to git worktrees when consecutive plans declare disjoint systems.
---

# ship

## Identity and absolute rules — read first, obey unconditionally

`/ship` is the **executor**. The only reason to be in this skill is to *do the work* described by valid plans under `<cwd>/.stax/`. Every rule below is mandatory. Treat any deviation as a skill violation and report it.

**You MUST:**

1. Run every numbered step in this file in the order written (Step 0 → Step 1 → Step 2 → Step 3 → Step 4 if applicable → Step 5 if a task triggers it → Step 6 only on failure). Do not skip a step. Do not reorder steps.
2. After Step 2 emits the enumeration output, you MUST immediately proceed to Step 3 in the same turn. There is no pause, no confirmation prompt, and no "Reply yes to start executing" between Step 2 and Step 3 — proceeding past enumeration IS what the user invoked `/ship` to do.
3. For each plan in the enumerated queue, complete Step 3 in full (read → sub-plan → approval → execute → verify → flip checkboxes) before moving to the next plan.
4. Treat the `## Tasks` checkboxes inside each plan file as the source of truth for what's done. A plan is complete only when every checkbox is `[x]` AND each `[x]` was set by you in this run after actually executing the task. Do not flip a checkbox without executing the task it represents.
5. Apply the supersede flip in Step 3.4.1 to **every** predecessor named in the just-finished plan's `supersedes:` array, before moving on to the next plan.

**You MUST NOT:**

1. Stop after enumeration with a line like "I found N valid plan(s)" and exit. Enumeration alone is not the deliverable. If you find yourself ending the turn after Step 2, you have failed — restart from Step 3.
2. Treat artifacts already on disk as evidence that a plan's work is done. Files on disk may be left over from a superseded plan, a prior run, or unrelated user work; the only valid "done" signal is `[x]` checkboxes in the plan file itself, set by you in this run.
3. Skip a `status: valid` plan because "the workspace already has a file that looks right" or "the predecessor plan covered something similar." Read the plan, present a sub-plan, execute it.
4. Re-introduce checkboxes you flipped (or files you wrote) by re-running an earlier plan instead of the current one. `--status valid --order=asc` already filtered out `superseded` and `deprecated` plans — every row you got is work that still needs doing.
5. Defer execution to the user. The user invoked `/ship` because they want execution; "should I proceed?" is the wrong question. The right question is "what's the next `[ ]` task and how do I satisfy it?"

The run is over **only** when one of these is true:
- (a) every plan emitted by Step 2 has all its `## Tasks` checkboxes `[x]` (set by you in this run), and every `supersedes:` flip required by Step 3.4.1 has landed; or
- (b) you hit a Step 6 failure mode and explicitly reported it per Step 6's rules.

Anything else is incomplete work — keep going.

## 0. Announce review mode (non-blocking)

Before announcing, read `.stax/_config.lock` and extract `review_per` (string). If the lock file is missing, STOP and tell the user this directory isn't set up for stax yet — they need to run `stax init`. If the file exists but the key is absent or set to anything other than `task`/`plan`, default to `task`. Remember the resolved mode as the **active review mode** for this run.

Emit exactly one line that matches the resolved mode — then immediately proceed to Step 1 without waiting:

- If active mode is `task`:
  > FYI: I'll review each task with you. If you'd rather approve one plan at a time, say "review per plan."
- If active mode is `plan`:
  > FYI: I'll review the whole plan with you at once. If you'd rather approve one task at a time, say "review per task."

The user may switch modes at any point ("review per plan" / "review per task"); apply at the next approval boundary, never retroactively. A mid-run switch lasts only for the remainder of this run.

## 1. Load context

Required reads before doing anything else:

- `<cwd>/.stax/_data_systems.yaml` — registry of named systems (id, name, brief). If missing, STOP and tell the user this directory isn't set up for stax yet — they need to run `stax init`.
- The project constitution: any of `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, or `.clinerules` at <cwd>. Read whichever is present and take it as the override on all defaults in this skill. `AGENTS.md` is the de-facto cross-agent convention (Kilocode, OpenCode, Codex, Cursor, Antigravity, pi, omp); the others are each agent's bespoke filename (`CLAUDE.md` for Claude Code, `GEMINI.md` for Gemini CLI, `.github/copilot-instructions.md` for GitHub Copilot, `.clinerules` for Cline). If none exist, suggest the user create one as a helpful tip and proceed.

The plan-first protocol (used by Step 3.3.2 when presenting sub-plans) is defined inline in Appendix A at the bottom of this file. Read it before the first approval prompt.

## 2. Enumerate plans

Run `stax plans list --status valid --order=asc`. Output is tab-separated, one row per plan, sorted by numerical prefix ascending (the default sort is descending; `--order=asc` gives the oldest-first execution order this skill iterates):

```
<slug>\t<status>\t<id>,<id>,...
```

All emitted rows are the work queue — the `--status valid` flag filters out `superseded` and `deprecated`. Files in `.stax/` that match `<prefix>-<slug>.md` but have missing or malformed frontmatter trigger stderr warnings from `stax`; flag those in your end-of-run summary so they aren't lost.

The third column is each plan's **scope** — the kebab `id:` of every system it touches, as declared in `<cwd>/.stax/_data_systems.yaml`.

**Step 2 → Step 3 transition (mandatory, no gap):** the moment enumeration finishes, you continue into Step 2a (progress tracking) and Step 3 (execution) in the same turn. Do not stop. Do not emit a "found N plans, proceed?" message. Do not wait for the user to confirm. The user already confirmed they want execution by invoking `/ship`; your job from Step 2's output forward is to actually execute. The only legitimate pause is the per-task or per-plan approval prompt inside Step 3.3.2 (governed by the active review mode from Step 0).

## 2a. Progress tracking

Always maintain a visible task list during execution. After enumeration, create one entry per plan in the work queue using your harness's task/todo-tracking capability (subject = plan slug, description = its scope). If your harness has no native task tool, keep an equivalent markdown checklist inline in your reply and update it as plans progress. Mark each entry `in_progress` when you start the plan's first incomplete EARS task and `completed` when the plan's last task is `[x]`. In parallel mode, give each worktree-bound plan its own entry. Keep the list in sync with reality — every status change reflects an actual execution event.

If the user enqueues new work mid-execution — a new plan dropped into `.stax/`, a new `[ ]` EARS criterion added to a running plan, or an out-of-band request — append it to the visible queue immediately so the queue stays complete. Never absorb new work silently. Prioritization (interrupt vs. queue-at-end) follows the user's instruction; default is queue-at-end unless they signal otherwise.

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
   1. If the plan's frontmatter includes `supersedes: [<slug>, ...]`, for each listed predecessor: edit its plan file to (a) flip `status: valid` → `status: superseded`, and (b) append this plan's slug to its `superseded_by:` array (create the array right before `created:` if absent). Both edits must land in the same revision — `stax plans lint` enforces that the supersedes ↔ superseded_by back link is symmetric. Treat each predecessor edit as a side effect that goes through the plan-first sub-plan protocol.
   2. Report one-line completion and move to the next plan.

## 4. Parallel mode (auto-detected)

If the next contiguous run of upcoming plans declares pairwise disjoint scopes (zero shared systems across them), propose fanning out to git worktrees.

On approval, for each plan in the parallel run:

1. Create an isolated git worktree (and a dedicated branch) off the current HEAD. Worktree path and branch name are your call — pick something that keeps the plan's prefix and slug recoverable.
2. Execute the plan inside its own worktree following the sequential rules above (sub-plans included).
3. On completion, leave the worktree intact and report the worktree path + branch.

Do not merge worktrees back, do not remove them, and do not modify any branch outside its own worktree. Cleanup and merge are the user's call.

## 5. Ground-truth lookup

When a task needs the current contract for a system (to extend, modify, or reason about existing behavior), run `stax plans list --status valid --system <id> --order=asc` (the kebab `id:` from `<cwd>/.stax/_data_systems.yaml`, not the display name), then read the listed plan files. Collect only `[x]` (completed) criteria naming that system, ordered by numerical prefix ascending. Treat that ordered list as the live contract. Never read `superseded` or `deprecated` plans for current truth — they are history.

## 6. Failure mode

If a task cannot be completed (command fails, user rejects the sub-plan, missing input), STOP that worktree's sequence and leave the checkbox `[ ]`. In sequential mode this halts everything. In parallel mode, sibling worktrees continue independently. At the end, report every blocking plan + task in one summary. No auto-merge, no auto-cleanup, no skipping past failures.

## Appendix A: Plan-first protocol

Every sub-plan presented for approval in Step 3.3.2 follows this protocol. The same protocol is used by the `scope` skill when authoring full plan files; here in `ship` it governs the approval prompts shown for each task (per-task) or each plan (per-plan).

### The protocol

0. **Load the context.** Already done in Step 1 — the constitution file and the systems registry are required reads.
1. **Gather inputs.** Receive inputs from the user, identify the intent, find related content. No state changes yet.
2. **Build the plan.** Compose the full set of changes you intend to make.
3. **Present the plan.** Output a clear plan to the user using the template below. End with the literal sentence:
   > Reply `yes` to proceed, or tell me what to change.
4. **Wait for approval.** Wait until the user replies. Any unambiguous affirmation counts as approval — `yes`, `y`, `yep`, `yeah`, `ok`, `okay`, `sure`, `lgtm`, `sounds good`, `proceed`, `go`, `go ahead`, `do it`, `ship it`, `confirm`, `accept`, `approved`, `affirmative`, `+1`, and similar. Anything ambiguous or that requests a change is a revision — go back to step 2 with the user's feedback.
5. **Execute.** Now execute what the user wanted. After each command, report what happened in one line.
6. **Summarize.** When done, give a one-line confirmation per entity created/changed/deleted.

### Sub-plan template

Every sub-plan must include:

- **Goal:** one-sentence description of the outcome.
- **Inputs already gathered:** what the skill found (plan slug, current state, related items).
- **Changes proposed:** every file that will be created/modified/deleted; every DB row that will change.
- **Named systems used:** which entries from `<cwd>/.stax/_data_systems.yaml`'s `systems` array the work targets.
- **Commands to run:** the exact shell commands or tool calls, in order.

### Plan file format (read-side, for executing plan files written by scope)

Every plan file under `<cwd>/.stax/` lives at `<prefix>-<slug>.md` with YAML frontmatter:

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

Body sections, in order: `## Goal`, `## Approach`, `## Tasks` (EARS-format checkboxes; `[ ]` open, `[x]` done — ship flips these as it executes).

### Plan tooling (the `stax plans` subcommands)

- `stax plans list [--status NAME[,NAME...]] [--system ID] [--order asc|desc] [--overflow-keywords PATTERN[,PATTERN...]]` — lists plans, one tab-separated row per plan: `<slug>\t<status>\t<id>,<id>,...`.
  - `--status` keeps only matching statuses. Repeatable; comma-separated values OK.
  - `--system` keeps only plans whose `systems:` array contains the given kebab id.
  - `--order` sorts by zero-padded prefix; default `desc`. Pass `--order=asc` when you need oldest-first execution order (this skill's work queue uses asc).
  - `--overflow-keywords` filters by body substring when row count exceeds the project's overflow threshold. Safe to omit.
- `stax plans lint` — validates every plan file. Exit 0 = all pass, exit 1 = at least one failure.

All `stax plans` commands read `prefix_width` / `max_plan_lines` from `<cwd>/.stax/_config.lock` (seeded by `stax init`).

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

## Before returning control — verification checklist

Before declaring this `/ship` invocation complete (i.e., before the final summary line that hands control back to the user), verify every one of the following. If any is false, you are not done — continue executing or apply the Step 6 failure protocol.

1. You ran `stax plans list --status valid --order=asc` exactly once at Step 2 and used its output verbatim as the work queue.
2. For every plan in that queue, you read the full plan file (Step 3.1) and either:
   - flipped every `[ ]` checkbox to `[x]` after actually executing the corresponding task and running the project's verify target (Step 3.3.1–3.3.5), or
   - left the run halted per Step 6 with a clear "blocking plan + task" summary.
3. For every plan in that queue whose frontmatter declares `supersedes: [<slug>, ...]`, you edited each named predecessor's frontmatter to set `status: superseded` AND append the current plan's slug to `superseded_by:` (Step 3.4.1). `stax plans lint` exits 0 after the edits.
4. The artifacts you produced satisfy the **most recent** valid plan's EARS criteria — not a superseded predecessor's. If a plan with `supersedes:` declares a different deliverable from its predecessor, the workspace must reflect the successor's deliverable (replacing or rewriting whatever the predecessor left behind), not coexist with predecessor artifacts.
5. You did NOT skip a plan because "the workspace looks done." Checkbox state in the plan file is the only authoritative completion signal.
6. You did NOT exit after Step 2 with a "found N plans" summary. Step 2's output is intermediate; Step 3 is the deliverable.

If you cannot answer "yes" to all six, the skill contract was violated. State which item failed, what you actually did, and either resume from the correct step or report the failure per Step 6.
