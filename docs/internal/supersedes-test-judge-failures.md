# Supersedes test: judge failures

Captured 2026-05-28. Two of six runs in the manual judge matrix failed,
both on the `*_reminders_supersedes_todo` scenario. Distinct root
causes per agent harness.

## Run 26554109428 — claude code, user scope

`test_claude_reminders_supersedes_todo` failed at `ArtifactJudge`:

> No produced files were listed; the executor produced no artifacts,
> failing the first evaluation step automatically.

Per `stax.jsonl`, `/ship` performed the supersedes status flip — three
`Edit` calls against `0001-…md` and `0002-…md` — and spawned four
subagents. It issued no `Write` for the successor work item's `index.html`.
Work-item-mechanics assertions (`status: superseded`, `superseded_by`,
`supersedes`) all passed; the workspace contained only `.stax/*`
when the judge ran. `actions/upload-artifact@v5` strips dotfiles by
default, so the uploaded `eval-workspace/` is empty.

Failure mode: executor under-reach. `/ship` did the frontmatter
bookkeeping but never built the artifact.

## Run 26554125840 — copilot cli, project scope

`test_copilot_reminders_supersedes_todo` failed at `ArtifactJudge`:

> The produced index.html is a todo list app, not the requested
> reminders app … implements a standard todo list instead.

Per `scope-todo.txt` turn 2: `/scope` wrote `index.html` (159 lines)
and ticked every checkbox in `0001-…md`. Per `scope-reminders.txt`
turn 2: `/scope` flipped `0001` to `status: superseded` and added the
`superseded_by` back-link. Per `stax.txt`: 5 lines of greeting, then
EOF. `/ship` had nothing left to execute because the planner had
already done the executor's job — implementation, checkbox flips, and
predecessor status flip.

The contract: `agents/skills/ship/SKILL.md:62` reserves checkbox flips
for `/ship`; `:64` reserves the predecessor `status: valid →
superseded` flip and the `superseded_by` back-link for `/ship`;
`agents/skills/scope/SKILL.md:45` constrains the planner to writing
the new work item with `status: valid` and an optional `supersedes:` entry.
The copilot harness violates all three during `/scope`.

Failure mode: planner over-reach. `/scope` performs executor actions
during planning, leaving the wrong artifact on disk when supersedes
lands.

## Detection gap

Work-item-mechanics assertions (`status == "superseded"`, etc.) check the
post-state, not the caller. They pass identically whether `/scope` or
`/ship` does the flip. `ArtifactJudge` is the only existing check that
catches the over-reach — and only because the planner happens to leave
the wrong artifact.

A direct assertion that every task checkbox in the successor work item
flipped to `[x]` after `/ship` ran would catch both failure modes
mechanically, without depending on the LLM judge. Same for an
assertion that the predecessor's `status` was still `valid` at the
moment `/ship` was invoked (i.e. that the flip happened during
execution, not planning).
