# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Copilot through work-item-supersede + artifact-replace.

Mirrors test_claude_reminders_supersedes_todo.py.

Sequence:
  1. /scope a todo list app.
  2. /scope a reminders app that SUPERSEDES the todo work item.
  3. /ship — executes the queue; per agents/skills/ship/SKILL.md step 3.4,
     when the executor finishes the successor work item it flips the
     predecessor's `status: valid` → `status: superseded` and appends
     the successor slug to the predecessor's `superseded_by:` array.

Two distinct assertion classes:

  Work-item mechanics (deterministic Python YAML parsing):
    - todo work item: status=superseded, superseded_by contains reminders slug
    - reminders work item: status=valid, supersedes contains todo slug

  Artifact correctness (DeepEval GEval via ArtifactJudge):
    - the final workspace contains a working REMINDERS app, not a todo
      list — even if the executor ran both work items in order, the reminders
      semantics must be present in the produced artifacts.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.copilot_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.judges import ArtifactJudge
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


def test_copilot_reminders_supersedes_todo(
  copilot_workspace: Path,
  tmp_path: Path,
) -> None:
  transcripts = tmp_path / "transcripts"

  # --- Work-item 1: todo list ---
  todo_run = drive_skill(
    copilot_workspace,
    f"/scope {TODO_TASK}",
    transcript_path=transcripts / "scope-todo.txt",
  )
  assert todo_run.exit_code == 0, (
    f"copilot exited {todo_run.exit_code} during /scope todo; "
    f"timed_out={todo_run.timed_out}; stderr:\n{todo_run.stderr_tail}"
  )
  assert todo_run.completed
  assert todo_run.turns < DEFAULT_MAX_TURNS, (
    f"/scope todo hit max_turns cap ({DEFAULT_MAX_TURNS}). Inspect "
    f"{transcripts / 'scope-todo.txt'}."
  )

  # --- Work-item 2: reminders (supersedes todo) ---
  reminders_run = drive_skill(
    copilot_workspace,
    f"/scope {REMINDERS_TASK}",
    transcript_path=transcripts / "scope-reminders.txt",
  )
  assert reminders_run.exit_code == 0, (
    f"copilot exited {reminders_run.exit_code} during /scope reminders; "
    f"timed_out={reminders_run.timed_out}; stderr:\n{reminders_run.stderr_tail}"
  )
  assert reminders_run.completed
  assert reminders_run.turns < DEFAULT_MAX_TURNS, (
    f"/scope reminders hit max_turns cap ({DEFAULT_MAX_TURNS}). Inspect "
    f"{transcripts / 'scope-reminders.txt'}."
  )

  # --- Execute ---
  exec_run = drive_skill(
    copilot_workspace,
    "/ship",
    transcript_path=transcripts / "stax.txt",
  )
  assert exec_run.exit_code == 0, (
    f"copilot exited {exec_run.exit_code} during /ship; "
    f"timed_out={exec_run.timed_out}; stderr:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed
  # No turn-cap assertion for /ship: legitimate execution of two work items
  # plus the supersede flip (SKILL.md step 3.4) needs more turns than
  # a tight cap allows under --review-per work-item. The supersede flip
  # itself is asserted directly via work-item-frontmatter inspection below,
  # so a missing flip surfaces precisely rather than as an
  # underspecified "hit cap" message.

  # --- Work-item mechanics ---
  work_items = load_all_work_items(copilot_workspace)
  assert len(work_items) == 2, (
    f"expected exactly 2 work-item files, got {len(work_items)}: "
    f"{[p.slug for p in work items]}"
  )
  todo_work_item, reminders_work_item = work_items  # numeric prefix asc

  assert todo_work_item.frontmatter.get("status") == "superseded", (
    f"todo work item should be status=superseded after /ship ran the "
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
  judgment = judge.evaluate(REMINDERS_TASK, copilot_workspace)
  print(f"\n[artifact] score={judgment.score:.2f} reason={judgment.reason}")
  assert judgment.passed, (
    f"ArtifactJudge failed for reminders task: score={judgment.score:.2f} "
    f"reason={judgment.reason}"
  )
