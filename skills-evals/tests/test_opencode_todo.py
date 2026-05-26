# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive OpenCode through /x-plan + /x-x for a TODO app task.

Mirror of test_claude_todo.py, adapted for OpenCode's headless model.
The key adaptation is that `opencode run` does not currently resolve
slash commands (anomalyco/opencode#7345), so the prompt is built by
INLINING the SKILL.md content via `compose_skill_prompt` rather than
sending `/x-plan <task>` verbatim. That sidesteps the resolver gap and
exercises the agent's behavior on the skill prompt directly.

Flow per the user's spec:
  1. The "user" (this test) invokes the x-plan skill prompt + TODO task.
     Auto-reply 'yes' until the planner stops asking.
  2. PlanJudge scores the plan file that landed under .x-plans/.
  3. The "user" invokes the x-x skill prompt. Auto-reply 'yes' until
     the executor stops asking.
  4. ArtifactJudge scores the files the executor produced.

Both judges are DeepEval GEval metrics backed by DeepSeek. A test
failure means either the skill misbehaved or the judge scored below
threshold.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.judges import ArtifactJudge, PlanJudge
from skills_evals.opencode_driver import (
  DEFAULT_MAX_TURNS,
  compose_skill_prompt,
  drive_skill,
  resolve_skill_template,
)

TASK = "build me a single HTML and localStorage-based todo list app"


def test_opencode_builds_todo_app(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- /x-plan (inlined SKILL.md content + task) ---
  plan_template = resolve_skill_template(workspace, "x-plan")
  plan_prompt = compose_skill_prompt(plan_template, TASK)
  plan_run = drive_skill(
    workspace,
    plan_prompt,
    transcript_path=transcripts / "x-plan.jsonl",
  )
  assert plan_run.exit_code == 0, (
    f"opencode exited {plan_run.exit_code} during /x-plan; "
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

  # --- /x-x (inlined SKILL.md content; no task — the executor reads
  # the queue from .x-plans/) ---
  exec_template = resolve_skill_template(workspace, "x-x")
  exec_prompt = compose_skill_prompt(
    exec_template,
    "Execute the planning queue in .x-plans/ as described above.",
  )
  exec_run = drive_skill(
    workspace,
    exec_prompt,
    transcript_path=transcripts / "x-x.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"opencode exited {exec_run.exit_code} during /x-x; "
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
