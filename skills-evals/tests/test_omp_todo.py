# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive omp through /skill:x-plan + /skill:x-x for a TODO app.

Mirror of test_claude_todo.py against the omp (oh-my-pi) driver. Same
TASK string, same judges, same thresholds — the only differences are
the agent binary executing the slash commands and the slash-command
form: omp registers skills as `/skill:<name>` (see
oh-my-pi packages/coding-agent/src/extensibility/skills.ts
`getSkillSlashCommandName`), not `/<name>`.

Flow per the user's spec:
  1. Invoke /skill:x-plan with the TODO task. Auto-reply 'yes' until
     the planner stops asking.
  2. PlanJudge scores the plan file that landed under .x-plans/.
  3. Invoke /skill:x-x. Auto-reply 'yes' until the executor stops asking.
  4. ArtifactJudge scores the files the executor produced.

Both judges are DeepEval GEval metrics backed by DeepSeek. A test
failure means either the skill misbehaved or the judge scored below
threshold.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.judges import ArtifactJudge, PlanJudge
from skills_evals.omp_driver import DEFAULT_MAX_TURNS, drive_skill

TASK = "build me a single HTML and localStorage-based todo list app"

PLAN_PROMPT = f"/skill:x-plan {TASK}"
EXEC_PROMPT = "/skill:x-x"


def test_omp_builds_todo_app(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- /skill:x-plan ---
  plan_run = drive_skill(
    workspace,
    PLAN_PROMPT,
    transcript_path=transcripts / "x-plan.jsonl",
  )
  assert plan_run.exit_code == 0, (
    f"omp exited {plan_run.exit_code} during /skill:x-plan; "
    f"timed_out={plan_run.timed_out}; stderr tail:\n{plan_run.stderr_tail}"
  )
  assert plan_run.completed, (
    f"/skill:x-plan did not complete cleanly: turns={plan_run.turns} "
    f"yes_replies={plan_run.yes_replies} timed_out={plan_run.timed_out}"
  )
  assert plan_run.turns < DEFAULT_MAX_TURNS, (
    f"/skill:x-plan hit the max_turns cap ({DEFAULT_MAX_TURNS}) — the "
    f"planner kept asking for confirmation past what we expected. "
    f"Inspect {transcripts / 'x-plan.jsonl'} to see what it was asking."
  )

  plan_judgment = PlanJudge().evaluate(TASK, workspace)
  print(f"\n[plan] score={plan_judgment.score:.2f} reason={plan_judgment.reason}")
  assert plan_judgment.passed, (
    f"PlanJudge failed: score={plan_judgment.score:.2f} "
    f"reason={plan_judgment.reason}"
  )

  # --- /skill:x-x ---
  exec_run = drive_skill(
    workspace,
    EXEC_PROMPT,
    transcript_path=transcripts / "x-x.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"omp exited {exec_run.exit_code} during /skill:x-x; "
    f"timed_out={exec_run.timed_out}; stderr tail:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed, (
    f"/skill:x-x did not complete cleanly: turns={exec_run.turns} "
    f"yes_replies={exec_run.yes_replies} timed_out={exec_run.timed_out}"
  )
  # No turn-cap assertion for /skill:x-x: the executor legitimately needs
  # many turns (one per plan-boundary review under --review-per plan,
  # plus whatever intermediate gates the agent emits). Downstream
  # exit_code / completed / ArtifactJudge assertions cover correctness;
  # a turn cap here would conflate "stuck at gate" with "did real work
  # that took turns" — only the former is a failure mode. (Same call
  # the Copilot driver makes — see test_copilot_todo.py.)

  artifact_judgment = ArtifactJudge().evaluate(TASK, workspace)
  print(f"\n[artifact] score={artifact_judgment.score:.2f} reason={artifact_judgment.reason}")
  assert artifact_judgment.passed, (
    f"ArtifactJudge failed: score={artifact_judgment.score:.2f} "
    f"reason={artifact_judgment.reason}"
  )
