# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Copilot through scope-supersede + artifact-replace.

Mirrors test_claude_reminders_supersedes_todo.py.

Sequence:
  1. /scope a todo list app.
  2. /scope a reminders app that SUPERSEDES the todo scope.
  3. /ship — executes the queue; per agents/skills/ship/SKILL.md step 3.4,
     when the executor finishes the successor scope it flips the
     predecessor's `status: valid` → `status: superseded` and appends
     the successor slug to the predecessor's `superseded_by:` array.

Two distinct assertion classes:

  Scope mechanics (deterministic Python YAML parsing):
    - todo scope: status=superseded, superseded_by contains reminders slug
    - reminders scope: status=valid, supersedes contains todo slug

  Artifact correctness (DeepEval GEval via ArtifactJudge):
    - the final workspace contains a working REMINDERS app, not a todo
      list — even if the executor ran both scopes in order, the reminders
      semantics must be present in the produced artifacts.
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.copilot_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.judges import ArtifactJudge
from skills_evals.workspace import load_all_scopes

TODO_TASK = "build a single HTML and localStorage-based todo list app"

REMINDERS_TASK = (
  "replace the previous todo list app with a single-page HTML reminders "
  "app backed by localStorage. The user can add a reminder, enable or "
  "disable a reminder (check on/off behavior similar to the todo app's "
  "checkbox), and delete a reminder. When a reminder's time arrives, the "
  "app must display a notification div alerting the user. This scope "
  "SUPERSEDES the previous todo list scope — mark it accordingly."
)


def test_copilot_reminders_supersedes_todo(
  copilot_workspace: Path,
  tmp_path: Path,
) -> None:
  transcripts = tmp_path / "transcripts"

  # --- Scope 1: todo list ---
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

  # --- Scope 2: reminders (supersedes todo) ---
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
  # No turn-cap assertion for /ship: legitimate execution of two scopes
  # plus the supersede flip (SKILL.md step 3.4) needs more turns than
  # a tight cap allows under --review-per scope. The supersede flip
  # itself is asserted directly via scope-frontmatter inspection below,
  # so a missing flip surfaces precisely rather than as an
  # underspecified "hit cap" message.

  # --- Scope mechanics ---
  scopes = load_all_scopes(copilot_workspace)
  assert len(scopes) == 2, (
    f"expected exactly 2 scope files, got {len(scopes)}: "
    f"{[p.slug for p in scopes]}"
  )
  todo_scope, reminders_scope = scopes  # numeric prefix asc

  assert todo_scope.frontmatter.get("status") == "superseded", (
    f"todo scope should be status=superseded after /ship ran the "
    f"successor, got {todo_scope.frontmatter.get('status')!r}"
  )
  superseded_by = todo_scope.frontmatter.get("superseded_by") or []
  assert reminders_scope.slug in superseded_by, (
    f"todo scope's superseded_by should include reminders slug "
    f"({reminders_scope.slug}); got {superseded_by!r}"
  )

  assert reminders_scope.frontmatter.get("status") == "valid", (
    f"reminders scope should remain status=valid, got "
    f"{reminders_scope.frontmatter.get('status')!r}"
  )
  supersedes = reminders_scope.frontmatter.get("supersedes") or []
  assert todo_scope.slug in supersedes, (
    f"reminders scope's supersedes should include todo slug "
    f"({todo_scope.slug}); got {supersedes!r}"
  )

  # --- Artifact correctness: must be a reminders app, not a todo ---
  judge = ArtifactJudge()
  judgment = judge.evaluate(REMINDERS_TASK, copilot_workspace)
  print(f"\n[artifact] score={judgment.score:.2f} reason={judgment.reason}")
  assert judgment.passed, (
    f"ArtifactJudge failed for reminders task: score={judgment.score:.2f} "
    f"reason={judgment.reason}"
  )
