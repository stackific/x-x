# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Kilo through two /x-plan calls that exercise the
extends mechanic.

Per agents/skills/x-plan/SKILL.md step 2a + step 3, when a new plan is
written that "extends" a predecessor (rather than supersedes it):
  - the new plan's frontmatter gets `extends: [<predecessor-slug>]`
  - the predecessor's frontmatter gets `extended_by: [<new-slug>]`
  - both plans stay `status: valid` (extends is a forward pointer, not a
    state change — unlike supersedes)

This test asserts both sides of that bidirectional link without running
/x-x (extends does not cause any execution-time state change).
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.kilo_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.workspace import load_all_plans

BASE_TASK = "build a single HTML and localStorage-based todo list app"
EXTENSION_TASK = (
  "add a 'clear all completed' button to the existing todo list app. "
  "This is a follow-up plan that extends the previous one — both plans "
  "should remain valid; do not supersede."
)


def test_kilo_plan_extends(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- Plan A: the base todo app ---
  a_run = drive_skill(
    workspace,
    f"/x-plan {BASE_TASK}",
    transcript_path=transcripts / "x-plan-a.jsonl",
  )
  assert a_run.exit_code == 0, (
    f"kilo exited {a_run.exit_code} during /x-plan A; "
    f"timed_out={a_run.timed_out}; stderr:\n{a_run.stderr_tail}"
  )
  assert a_run.completed, (
    f"/x-plan A did not complete cleanly: turns={a_run.turns} "
    f"yes_replies={a_run.yes_replies} timed_out={a_run.timed_out}"
  )
  assert a_run.turns < DEFAULT_MAX_TURNS

  # --- Plan B: extension of plan A ---
  b_run = drive_skill(
    workspace,
    f"/x-plan {EXTENSION_TASK}",
    transcript_path=transcripts / "x-plan-b.jsonl",
  )
  assert b_run.exit_code == 0, (
    f"kilo exited {b_run.exit_code} during /x-plan B; "
    f"timed_out={b_run.timed_out}; stderr:\n{b_run.stderr_tail}"
  )
  assert b_run.completed, (
    f"/x-plan B did not complete cleanly: turns={b_run.turns} "
    f"yes_replies={b_run.yes_replies} timed_out={b_run.timed_out}"
  )
  assert b_run.turns < DEFAULT_MAX_TURNS

  # --- Verify plan mechanics ---
  plans = load_all_plans(workspace)
  assert len(plans) == 2, (
    f"expected exactly 2 plan files, got {len(plans)}: "
    f"{[p.slug for p in plans]}"
  )
  plan_a, plan_b = plans  # sorted by filename = numeric prefix asc

  # Both plans stay valid — extends does not flip status.
  assert plan_a.frontmatter.get("status") == "valid", (
    f"plan A status should be 'valid' for extends, got "
    f"{plan_a.frontmatter.get('status')!r}"
  )
  assert plan_b.frontmatter.get("status") == "valid", (
    f"plan B status should be 'valid' for extends, got "
    f"{plan_b.frontmatter.get('status')!r}"
  )

  # New plan B has `extends: [plan_a.slug]`.
  extends_value = plan_b.frontmatter.get("extends") or []
  assert plan_a.slug in extends_value, (
    f"plan B should extend plan A ({plan_a.slug}); "
    f"plan B 'extends' = {extends_value!r}"
  )

  # Predecessor plan A has back-link `extended_by: [plan_b.slug]`.
  extended_by_value = plan_a.frontmatter.get("extended_by") or []
  assert plan_b.slug in extended_by_value, (
    f"plan A should be extended_by plan B ({plan_b.slug}); "
    f"plan A 'extended_by' = {extended_by_value!r}"
  )

  # supersedes should NOT have been written — this is extends, not supersedes.
  assert not plan_b.frontmatter.get("supersedes"), (
    f"plan B should NOT have supersedes for an extends scenario; "
    f"got {plan_b.frontmatter.get('supersedes')!r}"
  )
  assert not plan_a.frontmatter.get("superseded_by"), (
    f"plan A should NOT have superseded_by for an extends scenario; "
    f"got {plan_a.frontmatter.get('superseded_by')!r}"
  )
