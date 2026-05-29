# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Claude through two /scope calls that exercise the
extends mechanic.

Per agents/skills/scope/SKILL.md step 2a + step 3, when a new work item is
written that "extends" a predecessor (rather than supersedes it):
  - the new work item's frontmatter gets `extends: [<predecessor-slug>]`
  - the predecessor's frontmatter gets `extended_by: [<new-slug>]`
  - both work items stay `status: valid` (extends is a forward pointer, not a
    state change — unlike supersedes)

This test asserts both sides of that bidirectional link without running
/ship (extends does not cause any execution-time state change).
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.claude_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.workspace import load_all_work_items

BASE_TASK = "build a single HTML and localStorage-based todo list app"
EXTENSION_TASK = (
  "add a 'clear all completed' button to the existing todo list app. "
  "This is a follow-up work item that extends the previous one — both work items "
  "should remain valid; do not supersede."
)


def test_claude_work_item_extends(workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- Work-item A: the base todo app ---
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

  # --- Work-item B: extension of work item A ---
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

  # --- Verify work-item mechanics ---
  work_items = load_all_work_items(workspace)
  assert len(work_items) == 2, (
    f"expected exactly 2 work-item files, got {len(work_items)}: "
    f"{[p.slug for p in work_items]}"
  )
  work_item_a, work_item_b = work_items  # sorted by filename = numeric prefix asc

  # Both work items stay valid — extends does not flip status.
  assert work_item_a.frontmatter.get("status") == "valid", (
    f"work item A status should be 'valid' for extends, got "
    f"{work_item_a.frontmatter.get('status')!r}"
  )
  assert work_item_b.frontmatter.get("status") == "valid", (
    f"work item B status should be 'valid' for extends, got "
    f"{work_item_b.frontmatter.get('status')!r}"
  )

  # New work item B has `extends: [work_item_a.slug]`.
  extends_value = work_item_b.frontmatter.get("extends") or []
  assert work_item_a.slug in extends_value, (
    f"work item B should extend work item A ({work_item_a.slug}); "
    f"work item B 'extends' = {extends_value!r}"
  )

  # Predecessor work item A has back-link `extended_by: [work_item_b.slug]`.
  extended_by_value = work_item_a.frontmatter.get("extended_by") or []
  assert work_item_b.slug in extended_by_value, (
    f"work item A should be extended_by work item B ({work_item_b.slug}); "
    f"work item A 'extended_by' = {extended_by_value!r}"
  )

  # supersedes should NOT have been written — this is extends, not supersedes.
  assert not work_item_b.frontmatter.get("supersedes"), (
    f"work item B should NOT have supersedes for an extends scenario; "
    f"got {work_item_b.frontmatter.get('supersedes')!r}"
  )
  assert not work_item_a.frontmatter.get("superseded_by"), (
    f"work item A should NOT have superseded_by for an extends scenario; "
    f"got {work_item_a.frontmatter.get('superseded_by')!r}"
  )
