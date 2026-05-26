# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive OpenCode through plan-supersede + artifact-replace.

Mirror of test_claude_reminders_supersedes_todo.py adapted for the
OpenCode headless path. Each skill invocation inlines the SKILL.md
content via `compose_skill_prompt` because `opencode run` does not
currently resolve slash commands (anomalyco/opencode#7345).

Sequence:
  1. x-plan a todo list app.
  2. x-plan a reminders app that SUPERSEDES the todo plan.
  3. x-x — executes the queue; per agents/skills/x-x/SKILL.md step 3.4,
     when the executor finishes the successor plan it flips the
     predecessor's `status: valid` → `status: superseded` and appends
     the successor slug to the predecessor's `superseded_by:` array.

Two distinct assertion classes:

  Plan mechanics (deterministic Python YAML parsing):
    - todo plan: status=superseded, superseded_by contains reminders slug
    - reminders plan: status=valid, supersedes contains todo slug

  Artifact correctness (DeepEval GEval via ArtifactJudge):
    - the final workspace contains a working REMINDERS app, not a todo
      list — even if the executor ran both plans in order, the
      reminders semantics must be present in the produced artifacts.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.judges import ArtifactJudge
from skills_evals.opencode_driver import (
  DEFAULT_MAX_TURNS,
  compose_skill_prompt,
  drive_skill,
  resolve_skill_template,
)
from skills_evals.workspace import load_all_plans

TODO_TASK = "build a single HTML and localStorage-based todo list app"

REMINDERS_TASK = (
  "replace the previous todo list app with a single-page HTML reminders "
  "app backed by localStorage. The user can add a reminder, enable or "
  "disable a reminder (check on/off behavior similar to the todo app's "
  "checkbox), and delete a reminder. When a reminder's time arrives, the "
  "app must display a notification div alerting the user. This plan "
  "SUPERSEDES the previous todo list plan — mark it accordingly."
)


def test_opencode_reminders_supersedes_todo(
  workspace: Path, tmp_path: Path
) -> None:
  transcripts = tmp_path / "transcripts"
  plan_template = resolve_skill_template(workspace, "x-plan")
  exec_template = resolve_skill_template(workspace, "x-x")

  # --- Plan 1: todo list ---
  todo_run = drive_skill(
    workspace,
    compose_skill_prompt(plan_template, TODO_TASK),
    transcript_path=transcripts / "x-plan-todo.jsonl",
  )
  assert todo_run.exit_code == 0, (
    f"opencode exited {todo_run.exit_code} during /x-plan todo; "
    f"timed_out={todo_run.timed_out}; stderr:\n{todo_run.stderr_tail}"
  )
  assert todo_run.completed
  assert todo_run.turns < DEFAULT_MAX_TURNS

  # --- Plan 2: reminders (supersedes todo) ---
  reminders_run = drive_skill(
    workspace,
    compose_skill_prompt(plan_template, REMINDERS_TASK),
    transcript_path=transcripts / "x-plan-reminders.jsonl",
  )
  assert reminders_run.exit_code == 0, (
    f"opencode exited {reminders_run.exit_code} during /x-plan reminders; "
    f"timed_out={reminders_run.timed_out}; stderr:\n{reminders_run.stderr_tail}"
  )
  assert reminders_run.completed
  assert reminders_run.turns < DEFAULT_MAX_TURNS

  # --- Execute ---
  exec_run = drive_skill(
    workspace,
    compose_skill_prompt(
      exec_template,
      "Execute the planning queue in .x-plans/ as described above.",
    ),
    transcript_path=transcripts / "x-x.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"opencode exited {exec_run.exit_code} during /x-x; "
    f"timed_out={exec_run.timed_out}; stderr:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed
  assert exec_run.turns < DEFAULT_MAX_TURNS

  # --- Plan mechanics ---
  plans = load_all_plans(workspace)
  assert len(plans) == 2, (
    f"expected exactly 2 plan files, got {len(plans)}: "
    f"{[p.slug for p in plans]}"
  )
  todo_plan, reminders_plan = plans  # numeric prefix asc

  assert todo_plan.frontmatter.get("status") == "superseded", (
    f"todo plan should be status=superseded after /x-x ran the "
    f"successor, got {todo_plan.frontmatter.get('status')!r}"
  )
  superseded_by = todo_plan.frontmatter.get("superseded_by") or []
  assert reminders_plan.slug in superseded_by, (
    f"todo plan's superseded_by should include reminders slug "
    f"({reminders_plan.slug}); got {superseded_by!r}"
  )

  assert reminders_plan.frontmatter.get("status") == "valid", (
    f"reminders plan should remain status=valid, got "
    f"{reminders_plan.frontmatter.get('status')!r}"
  )
  supersedes = reminders_plan.frontmatter.get("supersedes") or []
  assert todo_plan.slug in supersedes, (
    f"reminders plan's supersedes should include todo slug "
    f"({todo_plan.slug}); got {supersedes!r}"
  )

  # --- Artifact correctness: must be a reminders app, not a todo ---
  judge = ArtifactJudge()
  judgment = judge.evaluate(REMINDERS_TASK, workspace)
  print(f"\n[artifact] score={judgment.score:.2f} reason={judgment.reason}")
  assert judgment.passed, (
    f"ArtifactJudge failed for reminders task: score={judgment.score:.2f} "
    f"reason={judgment.reason}"
  )
