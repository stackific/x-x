# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive OpenCode through /scope + /ship for a TODO app task.

Mirror of test_claude_todo.py, adapted for OpenCode's headless model.
opencode resolves slash commands via `--command <name>` by reading the
frontmatter `name:` field of SKILL.md files under
`.opencode/commands/`, `.claude/skills/`, and `.agents/skills/`. The
`stax init --agents opencode` install writes
`.opencode/commands/scope/SKILL.md` with `name: scope`, so
`drive_command(workspace, "scope", TASK)` exercises the same skill
the Claude tests exercise via `/scope TASK`.

Flow per the user's spec:
  1. Invoke the scope skill with the TODO task. Auto-reply 'yes' until
     the planner stops asking.
  2. PlanJudge scores the plan file that landed under .stax/.
  3. Invoke the stax skill. Auto-reply 'yes' until the executor stops
     asking.
  4. ArtifactJudge scores the files the executor produced.

Both judges are DeepEval GEval metrics backed by DeepSeek. A test
failure means either the skill misbehaved or the judge scored below
threshold.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.judges import ArtifactJudge, PlanJudge
from skills_evals.opencode_driver import DEFAULT_MAX_TURNS, drive_command

TASK = "build me a single HTML and localStorage-based todo list app"


def test_opencode_builds_todo_app(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- /scope ---
  plan_run = drive_command(
    workspace,
    "scope",
    TASK,
    transcript_path=transcripts / "scope.jsonl",
  )
  assert plan_run.exit_code == 0, (
    f"opencode exited {plan_run.exit_code} during /scope; "
    f"timed_out={plan_run.timed_out}; stderr tail:\n{plan_run.stderr_tail}"
  )
  assert plan_run.completed, (
    f"/scope did not complete cleanly: turns={plan_run.turns} "
    f"yes_replies={plan_run.yes_replies} timed_out={plan_run.timed_out}"
  )
  assert plan_run.turns < DEFAULT_MAX_TURNS, (
    f"/scope hit the max_turns cap ({DEFAULT_MAX_TURNS}) — the "
    f"planner kept asking for confirmation past what we expected. "
    f"Inspect {transcripts / 'scope.jsonl'} to see what it was asking."
  )

  plan_judgment = PlanJudge().evaluate(TASK, workspace)
  print(f"\n[plan] score={plan_judgment.score:.2f} reason={plan_judgment.reason}")
  assert plan_judgment.passed, (
    f"PlanJudge failed: score={plan_judgment.score:.2f} "
    f"reason={plan_judgment.reason}"
  )

  # --- /ship ---
  exec_run = drive_command(
    workspace,
    "ship",
    "",
    transcript_path=transcripts / "stax.jsonl",
  )
  assert exec_run.exit_code == 0, (
    f"opencode exited {exec_run.exit_code} during /ship; "
    f"timed_out={exec_run.timed_out}; stderr tail:\n{exec_run.stderr_tail}"
  )
  assert exec_run.completed, (
    f"/ship did not complete cleanly: turns={exec_run.turns} "
    f"yes_replies={exec_run.yes_replies} timed_out={exec_run.timed_out}"
  )
  assert exec_run.turns < DEFAULT_MAX_TURNS, (
    f"/ship hit the max_turns cap ({DEFAULT_MAX_TURNS}) — the executor "
    f"kept asking for confirmation past what we expected. Inspect "
    f"{transcripts / 'stax.jsonl'} to see what it was asking."
  )

  artifact_judgment = ArtifactJudge().evaluate(TASK, workspace)
  print(f"\n[artifact] score={artifact_judgment.score:.2f} reason={artifact_judgment.reason}")
  assert artifact_judgment.passed, (
    f"ArtifactJudge failed: score={artifact_judgment.score:.2f} "
    f"reason={artifact_judgment.reason}"
  )
