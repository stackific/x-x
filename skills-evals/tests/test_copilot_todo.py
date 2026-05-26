# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Copilot through /x-plan + /x-x for a TODO app task.

Mirrors test_claude_todo.py against the Copilot CLI driver. Same TASK
string, same judges, same thresholds — the only difference is the agent
binary executing the slash commands.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.copilot_driver import drive_skill
from skills_evals.judges import ArtifactJudge, PlanJudge

TASK = "build me a single HTML and localStorage-based todo list app"

PLAN_PROMPT = f"/x-plan {TASK}"
EXEC_PROMPT = "/x-x"


def test_copilot_builds_todo_app(copilot_workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- /x-plan ---
  plan_run = drive_skill(
    copilot_workspace,
    PLAN_PROMPT,
    transcript_path=transcripts / "x-plan.txt",
  )
  assert plan_run.exit_code == 0, (
    f"copilot exited {plan_run.exit_code} during /x-plan; "
    f"timed_out={plan_run.timed_out}; stderr tail:\n{plan_run.stderr_tail}"
  )
  assert plan_run.completed, (
    f"/x-plan did not complete cleanly: lines={plan_run.events_received} "
    f"timed_out={plan_run.timed_out}"
  )

  plan_judgment = PlanJudge().evaluate(TASK, copilot_workspace)
  print(f"\n[plan] score={plan_judgment.score:.2f} reason={plan_judgment.reason}")
  assert plan_judgment.passed, (
    f"PlanJudge failed: score={plan_judgment.score:.2f} "
    f"reason={plan_judgment.reason}"
  )

  # --- /x-x ---
  exec_run = drive_skill(
    copilot_workspace,
    EXEC_PROMPT,
    transcript_path=transcripts / "x-x.txt",
  )
  assert exec_run.exit_code == 0, (
    f"copilot exited {exec_run.exit_code} during /x-x; "
    f"timed_out={exec_run.timed_out}; stderr tail:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed, (
    f"/x-x did not complete cleanly: lines={exec_run.events_received} "
    f"timed_out={exec_run.timed_out}"
  )

  artifact_judgment = ArtifactJudge().evaluate(TASK, copilot_workspace)
  print(f"\n[artifact] score={artifact_judgment.score:.2f} reason={artifact_judgment.reason}")
  assert artifact_judgment.passed, (
    f"ArtifactJudge failed: score={artifact_judgment.score:.2f} "
    f"reason={artifact_judgment.reason}"
  )
