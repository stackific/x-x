# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Claude through two /scope calls that exercise the
extends mechanic.

Per agents/skills/scope/SKILL.md step 2a + step 3, when a new scope is
written that "extends" a predecessor (rather than supersedes it):
  - the new scope's frontmatter gets `extends: [<predecessor-slug>]`
  - the predecessor's frontmatter gets `extended_by: [<new-slug>]`
  - both scopes stay `status: valid` (extends is a forward pointer, not a
    state change — unlike supersedes)

This test asserts both sides of that bidirectional link without running
/ship (extends does not cause any execution-time state change).
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.claude_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.workspace import load_all_scopes

BASE_TASK = "build a single HTML and localStorage-based todo list app"
EXTENSION_TASK = (
  "add a 'clear all completed' button to the existing todo list app. "
  "This is a follow-up scope that extends the previous one — both scopes "
  "should remain valid; do not supersede."
)


def test_claude_plan_extends(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- Scope A: the base todo app ---
  a_run = drive_skill(
    workspace,
    f"/scope {BASE_TASK}",
    transcript_path=transcripts / "scope-a.jsonl",
  )
  assert a_run.exit_code == 0, (
    f"claude exited {a_run.exit_code} during /scope A; "
    f"timed_out={a_run.timed_out}; stderr:\n{a_run.stderr_tail}"
  )
  assert a_run.completed, (
    f"/scope A did not complete cleanly: turns={a_run.turns} "
    f"yes_replies={a_run.yes_replies} timed_out={a_run.timed_out}"
  )
  assert a_run.turns < DEFAULT_MAX_TURNS

  # --- Scope B: extension of scope A ---
  b_run = drive_skill(
    workspace,
    f"/scope {EXTENSION_TASK}",
    transcript_path=transcripts / "scope-b.jsonl",
  )
  assert b_run.exit_code == 0, (
    f"claude exited {b_run.exit_code} during /scope B; "
    f"timed_out={b_run.timed_out}; stderr:\n{b_run.stderr_tail}"
  )
  assert b_run.completed, (
    f"/scope B did not complete cleanly: turns={b_run.turns} "
    f"yes_replies={b_run.yes_replies} timed_out={b_run.timed_out}"
  )
  assert b_run.turns < DEFAULT_MAX_TURNS

  # --- Verify scope mechanics ---
  scopes = load_all_scopes(workspace)
  assert len(scopes) == 2, (
    f"expected exactly 2 scope files, got {len(scopes)}: "
    f"{[p.slug for p in scopes]}"
  )
  plan_a, plan_b = scopes  # sorted by filename = numeric prefix asc

  # Both scopes stay valid — extends does not flip status.
  assert plan_a.frontmatter.get("status") == "valid", (
    f"scope A status should be 'valid' for extends, got "
    f"{plan_a.frontmatter.get('status')!r}"
  )
  assert plan_b.frontmatter.get("status") == "valid", (
    f"scope B status should be 'valid' for extends, got "
    f"{plan_b.frontmatter.get('status')!r}"
  )

  # New scope B has `extends: [plan_a.slug]`.
  extends_value = plan_b.frontmatter.get("extends") or []
  assert plan_a.slug in extends_value, (
    f"scope B should extend scope A ({plan_a.slug}); "
    f"scope B 'extends' = {extends_value!r}"
  )

  # Predecessor scope A has back-link `extended_by: [plan_b.slug]`.
  extended_by_value = plan_a.frontmatter.get("extended_by") or []
  assert plan_b.slug in extended_by_value, (
    f"scope A should be extended_by scope B ({plan_b.slug}); "
    f"scope A 'extended_by' = {extended_by_value!r}"
  )

  # supersedes should NOT have been written — this is extends, not supersedes.
  assert not plan_b.frontmatter.get("supersedes"), (
    f"scope B should NOT have supersedes for an extends scenario; "
    f"got {plan_b.frontmatter.get('supersedes')!r}"
  )
  assert not plan_a.frontmatter.get("superseded_by"), (
    f"scope A should NOT have superseded_by for an extends scenario; "
    f"got {plan_a.frontmatter.get('superseded_by')!r}"
  )
