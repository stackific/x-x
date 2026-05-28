# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Cline through /x-plan + /x-x for a TODO app task.

Mirror of test_claude_todo.py, adapted for Cline's headless model.
Cline's `--yolo` CLI is a one-shot subprocess that auto-approves every
tool call and does NOT resolve slash commands from disk in headless
mode, so the driver inlines SKILL.md off `<workspace>/.claude/skills/`
into the prompt. `x-x init --agents claude` (transitional value for
cline; see AGENT_INIT_VALUE_FOR_KEY) is what placed those SKILL.md
files where the driver reads them.

Flow per the user's spec:
  1. Invoke the x-plan skill with the TODO task. The CI directive
     baked into the inlined prompt instructs the model to auto-approve
     every gate the SKILL TEMPLATE describes.
  2. PlanJudge scores the plan file that landed under .x-plans/.
  3. Invoke the x-x skill. Same auto-approve directive.
  4. ArtifactJudge scores the files the executor produced.

Both judges are DeepEval GEval metrics backed by DeepSeek. A test
failure means either the skill misbehaved or the judge scored below
threshold.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.cline_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.judges import ArtifactJudge, PlanJudge

TASK = "build me a single HTML and localStorage-based todo list app"


def test_cline_builds_todo_app(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- /x-plan ---
  plan_run = drive_skill(
    workspace,
    "x-plan",
    TASK,
    transcript_path=transcripts / "x-plan.jsonl",
  )
  assert plan_run.exit_code == 0, (
    f"cline exited {plan_run.exit_code} during /x-plan; "
    f"timed_out={plan_run.timed_out}; stderr tail:\n{plan_run.stderr_tail}"
  )
  assert plan_run.completed, (
    f"/x-plan did not complete cleanly: turns={plan_run.turns} "
    f"yes_replies={plan_run.yes_replies} timed_out={plan_run.timed_out}"
  )
  assert plan_run.turns < DEFAULT_MAX_TURNS, (
    f"/x-plan hit the max_turns cap ({DEFAULT_MAX_TURNS}) — the "
    f"planner kept asking for confirmation past what we expected. "
    f"Inspect {transcripts / 'x-plan.jsonl'} to see what it was asking."
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
    "x-x",
    "",
    transcript_path=transcripts / "x-x.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"cline exited {exec_run.exit_code} during /x-x; "
    f"timed_out={exec_run.timed_out}; stderr tail:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed, (
    f"/x-x did not complete cleanly: turns={exec_run.turns} "
    f"yes_replies={exec_run.yes_replies} timed_out={exec_run.timed_out}"
  )
  # No turn-cap assertion for /x-x: legitimate execution under
  # --review-per plan can legitimately use more turns than the cap; the
  # supersede flip is asserted directly in test_cline_reminders... via
  # plan-frontmatter inspection. Downstream exit_code/completed/judge
  # assertions cover correctness without conflating "stuck at gate" with
  # "did real work that took turns".

  artifact_judgment = ArtifactJudge().evaluate(TASK, workspace)
  print(f"\n[artifact] score={artifact_judgment.score:.2f} reason={artifact_judgment.reason}")
  assert artifact_judgment.passed, (
    f"ArtifactJudge failed: score={artifact_judgment.score:.2f} "
    f"reason={artifact_judgment.reason}"
  )
