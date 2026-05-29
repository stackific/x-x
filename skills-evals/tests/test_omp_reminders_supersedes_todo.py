# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive omp through work-item-supersede + artifact-replace.

Mirror of test_claude_reminders_supersedes_todo.py against the omp driver.

Sequence:
  1. /skill:scope a todo list app.
  2. /skill:scope a reminders app that SUPERSEDES the todo work item.
  3. /skill:stax — executes the queue; per agents/skills/ship/SKILL.md step
     3.4, when the executor finishes the successor work item it flips the
     predecessor's `status: valid` → `status: superseded` and appends
     the successor slug to the predecessor's `superseded_by:` array.

Two distinct assertion classes:

  Work-item mechanics (deterministic Python YAML parsing):
    - todo work item: status=superseded, superseded_by contains reminders slug
    - reminders work item: status=valid, supersedes contains todo slug

  Artifact correctness (DeepEval GEval via ArtifactJudge):
    - the final workspace contains a working REMINDERS app, not a todo
      list — even if the executor ran both work items in order, the
      reminders semantics must be present in the produced artifacts.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.judges import ArtifactJudge
from skills_evals.omp_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.workspace import load_all_work_items

TODO_TASK = "build a single HTML and localStorage-based todo list app"

REMINDERS_TASK = (
  "replace the previous todo list app with a single-page HTML reminders "
  "app backed by localStorage. The user can add a reminder, enable or "
  "disable a reminder (check on/off behavior similar to the todo app's "
  "checkbox), and delete a reminder. When a reminder's time arrives, the "
  "app must display a notification div alerting the user. This work item "
  "SUPERSEDES the previous todo list work item — mark it accordingly."
)


def test_omp_reminders_supersedes_todo(
  workspace: Path, tmp_path: Path
) -> None:
  transcripts = tmp_path / "transcripts"

  # --- Work-item 1: todo list ---
  todo_run = drive_skill(
    workspace,
    f"/skill:scope {TODO_TASK}",
    transcript_path=transcripts / "scope-todo.jsonl",
  )
  assert todo_run.exit_code == 0, (
    f"omp exited {todo_run.exit_code} during /skill:scope todo; "
    f"timed_out={todo_run.timed_out}; stderr:\n{todo_run.stderr_tail}"
  )
  assert todo_run.completed
  assert todo_run.turns < DEFAULT_MAX_TURNS

  # --- Work-item 2: reminders (supersedes todo) ---
  reminders_run = drive_skill(
    workspace,
    f"/skill:scope {REMINDERS_TASK}",
    transcript_path=transcripts / "scope-reminders.jsonl",
  )
  assert reminders_run.exit_code == 0, (
    f"omp exited {reminders_run.exit_code} during /skill:scope reminders; "
    f"timed_out={reminders_run.timed_out}; stderr:\n{reminders_run.stderr_tail}"
  )
  assert reminders_run.completed
  assert reminders_run.turns < DEFAULT_MAX_TURNS

  # --- Execute ---
  exec_run = drive_skill(
    workspace,
    "/skill:stax",
    transcript_path=transcripts / "stax.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"omp exited {exec_run.exit_code} during /skill:stax; "
    f"timed_out={exec_run.timed_out}; stderr:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed
  # No turn-cap on /skill:stax — see test_omp_todo.py for the rationale.

  # --- Work-item mechanics ---
  work_items = load_all_work_items(workspace)
  assert len(work_items) == 2, (
    f"expected exactly 2 work-item files, got {len(work_items)}: "
    f"{[p.slug for p in work_items]}"
  )
  todo_work_item, reminders_work_item = work_items  # numeric prefix asc

  assert todo_work_item.frontmatter.get("status") == "superseded", (
    f"todo work item should be status=superseded after /skill:stax ran the "
    f"successor, got {todo_work_item.frontmatter.get('status')!r}"
  )
  superseded_by = todo_work_item.frontmatter.get("superseded_by") or []
  assert reminders_work_item.slug in superseded_by, (
    f"todo work item's superseded_by should include reminders slug "
    f"({reminders_work_item.slug}); got {superseded_by!r}"
  )

  assert reminders_work_item.frontmatter.get("status") == "valid", (
    f"reminders work item should remain status=valid, got "
    f"{reminders_work_item.frontmatter.get('status')!r}"
  )
  supersedes = reminders_work_item.frontmatter.get("supersedes") or []
  assert todo_work_item.slug in supersedes, (
    f"reminders work item's supersedes should include todo slug "
    f"({todo_work_item.slug}); got {supersedes!r}"
  )

  # --- Artifact correctness: must be a reminders app, not a todo ---
  judge = ArtifactJudge()
  judgment = judge.evaluate(REMINDERS_TASK, workspace)
  print(f"\n[artifact] score={judgment.score:.2f} reason={judgment.reason}")
  assert judgment.passed, (
    f"ArtifactJudge failed for reminders task: score={judgment.score:.2f} "
    f"reason={judgment.reason}"
  )
