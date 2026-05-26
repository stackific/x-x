# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Claude through /x-plan + /x-x for a TODO app task.

Flow per the user's spec:
  1. The "user" (this test) invokes /x-plan with the TODO task. Auto-reply
     'yes' until /x-plan stops asking.
  2. PlanJudge scores the plan file that landed under .x-plans/.
  3. The "user" invokes /x-x. Auto-reply 'yes' until /x-x stops asking.
  4. ArtifactJudge scores the files the executor produced.

Both judges are DeepEval GEval metrics backed by DeepSeek. A test failure
means either the skill misbehaved or the judge scored below threshold.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from skills_evals.claude_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.judges import ArtifactJudge, PlanJudge

TASK = "build me a single HTML and localStorage-based todo list app"

PLAN_PROMPT = f"/x-plan {TASK}"
EXEC_PROMPT = "/x-x"


def test_claude_builds_todo_app(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- /x-plan ---
  plan_run = drive_skill(
    workspace,
    PLAN_PROMPT,
    transcript_path=transcripts / "x-plan.jsonl",
  )
  assert plan_run.exit_code == 0, (
    f"claude exited {plan_run.exit_code} during /x-plan; "
    f"timed_out={plan_run.timed_out}; stderr tail:\n{plan_run.stderr_tail}"
  )
  assert plan_run.completed, (
    f"/x-plan did not complete cleanly: turns={plan_run.turns} "
    f"yes_replies={plan_run.yes_replies} timed_out={plan_run.timed_out}"
  )
  assert plan_run.turns < DEFAULT_MAX_TURNS, (
    f"/x-plan hit the max_turns cap ({DEFAULT_MAX_TURNS}) — the planner "
    f"kept asking for confirmation past what we expected. Inspect "
    f"{transcripts / 'x-plan.jsonl'} to see what it was asking."
  )

  plan_judgment = PlanJudge().evaluate(TASK, workspace)
  print(f"\n[plan] score={plan_judgment.score:.2f} reason={plan_judgment.reason}")
  assert plan_judgment.passed, (
    f"PlanJudge failed: score={plan_judgment.score:.2f} "
    f"reason={plan_judgment.reason}"
  )

  # --- /x-x ---
  exec_run = drive_skill(
    workspace,
    EXEC_PROMPT,
    transcript_path=transcripts / "x-x.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"claude exited {exec_run.exit_code} during /x-x; "
    f"timed_out={exec_run.timed_out}; stderr tail:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed, (
    f"/x-x did not complete cleanly: turns={exec_run.turns} "
    f"yes_replies={exec_run.yes_replies} timed_out={exec_run.timed_out}"
  )
  assert exec_run.turns < DEFAULT_MAX_TURNS, (
    f"/x-x hit the max_turns cap ({DEFAULT_MAX_TURNS}) — the executor "
    f"kept asking for confirmation past what we expected. Inspect "
    f"{transcripts / 'x-x.jsonl'} to see what it was asking."
  )

  artifact_judgment = ArtifactJudge().evaluate(TASK, workspace)
  print(f"\n[artifact] score={artifact_judgment.score:.2f} reason={artifact_judgment.reason}")
  assert artifact_judgment.passed, (
    f"ArtifactJudge failed: score={artifact_judgment.score:.2f} "
    f"reason={artifact_judgment.reason}"
  )
