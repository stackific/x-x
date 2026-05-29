# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Copilot through /scope + /ship for a TODO app task.

Mirrors test_claude_todo.py against the Copilot CLI driver. Same TASK
string, same judges, same thresholds — the only difference is the agent
binary executing the slash commands.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.copilot_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.judges import ArtifactJudge, WorkItemJudge

TASK = "build me a single HTML and localStorage-based todo list app"

PLAN_PROMPT = f"/scope {TASK}"
EXEC_PROMPT = "/ship"


def test_copilot_builds_todo_app(copilot_workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- /scope ---
  plan_run = drive_skill(
    copilot_workspace,
    PLAN_PROMPT,
    transcript_path=transcripts / "scope.txt",
  )
  assert plan_run.exit_code == 0, (
    f"copilot exited {plan_run.exit_code} during /scope; "
    f"timed_out={plan_run.timed_out}; stderr tail:\n{plan_run.stderr_tail}"
  )
  assert plan_run.completed, (
    f"/scope did not complete cleanly: lines={plan_run.events_received} "
    f"timed_out={plan_run.timed_out}"
  )
  assert plan_run.turns < DEFAULT_MAX_TURNS, (
    f"/scope hit the max_turns cap ({DEFAULT_MAX_TURNS}) — the planner "
    f"kept gating on 'Reply yes' past what we expected. Inspect "
    f"{transcripts / 'scope.txt'} to see what it was asking."
  )

  work_item_judgment = WorkItemJudge().evaluate(TASK, copilot_workspace)
  print(f"\n[work-item] score={work_item_judgment.score:.2f} reason={work_item_judgment.reason}")
  assert work_item_judgment.passed, (
    f"WorkItemJudge failed: score={work_item_judgment.score:.2f} "
    f"reason={work_item_judgment.reason}"
  )

  # --- /ship ---
  exec_run = drive_skill(
    copilot_workspace,
    EXEC_PROMPT,
    transcript_path=transcripts / "stax.txt",
  )
  assert exec_run.exit_code == 0, (
    f"copilot exited {exec_run.exit_code} during /ship; "
    f"timed_out={exec_run.timed_out}; stderr tail:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed, (
    f"/ship did not complete cleanly: lines={exec_run.events_received} "
    f"timed_out={exec_run.timed_out}"
  )
  # No turn-cap assertion for /ship: the executor legitimately needs
  # many turns (one per work-item-boundary review under --review-per work-item,
  # plus whatever intermediate gates the agent emits). Downstream
  # exit_code/completed/ArtifactJudge assertions cover correctness;
  # a turn cap here would conflate "stuck at gate" with "did real work
  # that took turns" — only the former is a failure mode.

  artifact_judgment = ArtifactJudge().evaluate(TASK, copilot_workspace)
  print(f"\n[artifact] score={artifact_judgment.score:.2f} reason={artifact_judgment.reason}")
  assert artifact_judgment.passed, (
    f"ArtifactJudge failed: score={artifact_judgment.score:.2f} "
    f"reason={artifact_judgment.reason}"
  )
