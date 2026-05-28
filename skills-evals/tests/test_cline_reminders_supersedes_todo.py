# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Cline through plan-supersede + artifact-replace.

Mirrors test_claude_reminders_supersedes_todo.py.

Sequence:
  1. /scope a todo list app.
  2. /scope a reminders app that SUPERSEDES the todo plan.
  3. /ship — executes the queue; per agents/skills/ship/SKILL.md step 3.4,
     when the executor finishes the successor plan it flips the
     predecessor's `status: valid` → `status: superseded` and appends
     the successor slug to the predecessor's `superseded_by:` array.

Two distinct assertion classes:

  Plan mechanics (deterministic Python YAML parsing):
    - todo plan: status=superseded, superseded_by contains reminders slug
    - reminders plan: status=valid, supersedes contains todo slug

  Artifact correctness (DeepEval GEval via ArtifactJudge):
    - the final workspace contains a working REMINDERS app, not a todo
      list — even if the executor ran both plans in order, the reminders
      semantics must be present in the produced artifacts.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.cline_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.judges import ArtifactJudge
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


def test_cline_reminders_supersedes_todo(
  workspace: Path,
  tmp_path: Path,
) -> None:
  transcripts = tmp_path / "transcripts"

  # --- Plan 1: todo list ---
  todo_run = drive_skill(
    workspace,
    "scope",
    TODO_TASK,
    transcript_path=transcripts / "scope-todo.jsonl",
  )
  assert todo_run.exit_code == 0, (
    f"cline exited {todo_run.exit_code} during /scope todo; "
    f"timed_out={todo_run.timed_out}; stderr:\n{todo_run.stderr_tail}"
  )
  assert todo_run.completed
  assert todo_run.turns < DEFAULT_MAX_TURNS, (
    f"/scope todo hit max_turns cap ({DEFAULT_MAX_TURNS}). Inspect "
    f"{transcripts / 'scope-todo.jsonl'}."
  )

  # --- Plan 2: reminders (supersedes todo) ---
  reminders_run = drive_skill(
    workspace,
    "scope",
    REMINDERS_TASK,
    transcript_path=transcripts / "scope-reminders.jsonl",
  )
  assert reminders_run.exit_code == 0, (
    f"cline exited {reminders_run.exit_code} during /scope reminders; "
    f"timed_out={reminders_run.timed_out}; stderr:\n{reminders_run.stderr_tail}"
  )
  assert reminders_run.completed
  assert reminders_run.turns < DEFAULT_MAX_TURNS, (
    f"/scope reminders hit max_turns cap ({DEFAULT_MAX_TURNS}). Inspect "
    f"{transcripts / 'scope-reminders.jsonl'}."
  )

  # --- Execute ---
  exec_run = drive_skill(
    workspace,
    "ship",
    "",
    transcript_path=transcripts / "stax.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"cline exited {exec_run.exit_code} during /ship; "
    f"timed_out={exec_run.timed_out}; stderr:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed
  # No turn-cap assertion for /ship: legitimate execution of two plans
  # plus the supersede flip (SKILL.md step 3.4) needs more turns than
  # a tight cap allows under --review-per plan. The supersede flip
  # itself is asserted directly via plan-frontmatter inspection below.

  # --- Plan mechanics ---
  plans = load_all_plans(workspace)
  assert len(plans) == 2, (
    f"expected exactly 2 plan files, got {len(plans)}: "
    f"{[p.slug for p in plans]}"
  )
  todo_plan, reminders_plan = plans  # numeric prefix asc

  assert todo_plan.frontmatter.get("status") == "superseded", (
    f"todo plan should be status=superseded after /ship ran the "
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
