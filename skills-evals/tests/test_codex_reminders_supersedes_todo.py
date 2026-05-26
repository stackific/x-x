# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Codex through plan-supersede + artifact-replace.

Mirror of test_claude_reminders_supersedes_todo.py against the Codex
driver. The plan-mechanics + artifact assertions are agent-agnostic;
only the driver import changes.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.codex_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.judges import ArtifactJudge
from skills_evals.workspace import load_all_plans

pytestmark = pytest.mark.skipif(
  shutil.which("codex") is None,
  reason="`codex` CLI not on PATH — codex suite is skipped on runs that "
         "target a different backend",
)

TODO_TASK = "build a single HTML and localStorage-based todo list app"

REMINDERS_TASK = (
  "replace the previous todo list app with a single-page HTML reminders "
  "app backed by localStorage. The user can add a reminder, enable or "
  "disable a reminder (check on/off behavior similar to the todo app's "
  "checkbox), and delete a reminder. When a reminder's time arrives, the "
  "app must display a notification div alerting the user. This plan "
  "SUPERSEDES the previous todo list plan — mark it accordingly."
)


def test_codex_reminders_supersedes_todo(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  todo_run = drive_skill(
    workspace,
    f"/x-plan {TODO_TASK}",
    transcript_path=transcripts / "x-plan-todo.jsonl",
  )
  assert todo_run.exit_code == 0, (
    f"codex exited {todo_run.exit_code} during /x-plan todo; "
    f"timed_out={todo_run.timed_out}; stderr:\n{todo_run.stderr_tail}"
  )
  assert todo_run.completed
  assert todo_run.turns < DEFAULT_MAX_TURNS

  reminders_run = drive_skill(
    workspace,
    f"/x-plan {REMINDERS_TASK}",
    transcript_path=transcripts / "x-plan-reminders.jsonl",
  )
  assert reminders_run.exit_code == 0, (
    f"codex exited {reminders_run.exit_code} during /x-plan reminders; "
    f"timed_out={reminders_run.timed_out}; stderr:\n{reminders_run.stderr_tail}"
  )
  assert reminders_run.completed
  assert reminders_run.turns < DEFAULT_MAX_TURNS

  exec_run = drive_skill(
    workspace,
    "/x-x",
    transcript_path=transcripts / "x-x.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"codex exited {exec_run.exit_code} during /x-x; "
    f"timed_out={exec_run.timed_out}; stderr:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed
  assert exec_run.turns < DEFAULT_MAX_TURNS

  plans = load_all_plans(workspace)
  assert len(plans) == 2, (
    f"expected exactly 2 plan files, got {len(plans)}: "
    f"{[p.slug for p in plans]}"
  )
  todo_plan, reminders_plan = plans

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

  judge = ArtifactJudge()
  judgment = judge.evaluate(REMINDERS_TASK, workspace)
  print(f"\n[artifact] score={judgment.score:.2f} reason={judgment.reason}")
  assert judgment.passed, (
    f"ArtifactJudge failed for reminders task: score={judgment.score:.2f} "
    f"reason={judgment.reason}"
  )
