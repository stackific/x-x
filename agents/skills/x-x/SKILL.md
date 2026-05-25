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

Skills install into a folder we call `<skills_root>`, which is either `.claude/skills/` (Claude Code) or `.agents/skills/` (other agents).

`<skills_root>` can exist at two scopes:
- **Project scope**: `<cwd>/.claude/skills/` or `<cwd>/.agents/skills/`
- **User scope**: `.claude/skills/` or `.agents/skills/` in the user's home directory

When a reference like `../_x-x_shared/...` appears, resolve it against `<skills_root>/_x-x_shared/`. Check project scope first, then user scope. If the file is missing from both, STOP and report to the user.

Now load context per **Context to load** in `../_x-x_shared/_plan_first.md`. If any required file is missing, STOP and report.

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
      - **Per-task:** present a sub-plan for this task per `../_x-x_shared/_plan_first.md` and wait for `yes`.
      - **Per-plan:** on the first incomplete task of the plan, present **one** consolidated sub-plan listing every incomplete `[ ]` task in this plan and all their side effects; wait for a single `yes`. For subsequent tasks in the same plan, skip the prompt — the bundle approval covers them. A verification failure (step 3.3.4) halts the plan per Step 6; bundle approval does not survive a failed task.
   3. Execute. After each command, report what happened in one line.
   4. **Verify before flipping.** If the task added new code paths (endpoint, worker, parser, adapter, signal handler, etc.), write at least one unit or smoke test exercising the new path in the project's test layout. Then run the project's canonical test + lint + type-check target, if exists. They MUST exit 0 before the checkbox flips. If verification fails, leave the checkbox `[ ]` and apply the failure-mode protocol in step 6. Pure config / doc / registry / settings edits skip the test-write step but still run lint + type-checks.
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
