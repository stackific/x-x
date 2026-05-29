# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""End-to-end: drive Copilot through two /scope calls that exercise
the extends mechanic.

Mirrors test_claude_work_item_extends.py — same TASK strings, same work-item-file
assertions. Per agents/skills/scope/SKILL.md step 2a + step 3, a work item
that extends a predecessor must:
  - write `extends: [<predecessor-slug>]` into the new work item's frontmatter
  - write `extended_by: [<new-slug>]` into the predecessor's frontmatter
  - leave both at `status: valid` (extends is a forward pointer, not a
    state change — unlike supersedes)
"""

from __future__ import annotations

from pathlib import Path

from skills_evals.copilot_driver import DEFAULT_MAX_TURNS, drive_skill
from skills_evals.workspace import load_all_work_items

BASE_TASK = "build a single HTML and localStorage-based todo list app"
EXTENSION_TASK = (
  "add a 'clear all completed' button to the existing todo list app. "
  "This is a follow-up work item that extends the previous one — both work items "
  "should remain valid; do not supersede."
)


def test_copilot_work_item_extends(copilot_workspace: Path, tmp_path: Path) -> None:
  transcripts = tmp_path / "transcripts"

  # --- Work-item A: the base todo app ---
  a_run = drive_skill(
    copilot_workspace,
    f"/scope {BASE_TASK}",
    transcript_path=transcripts / "scope-a.txt",
  )
  assert a_run.exit_code == 0, (
    f"copilot exited {a_run.exit_code} during /scope A; "
    f"timed_out={a_run.timed_out}; stderr:\n{a_run.stderr_tail}"
  )
  assert a_run.completed, (
    f"/scope A did not complete cleanly: lines={a_run.events_received} "
    f"timed_out={a_run.timed_out}"
  )
  assert a_run.turns < DEFAULT_MAX_TURNS, (
    f"/scope A hit the max_turns cap ({DEFAULT_MAX_TURNS}) — gate kept "
    f"firing. Inspect {transcripts / 'scope-a.txt'}."
  )

  # --- Work-item B: extension of work item A ---
  b_run = drive_skill(
    copilot_workspace,
    f"/scope {EXTENSION_TASK}",
    transcript_path=transcripts / "scope-b.txt",
  )
  assert b_run.exit_code == 0, (
    f"copilot exited {b_run.exit_code} during /scope B; "
    f"timed_out={b_run.timed_out}; stderr:\n{b_run.stderr_tail}"
  )
  assert b_run.completed, (
    f"/scope B did not complete cleanly: lines={b_run.events_received} "
    f"timed_out={b_run.timed_out}"
  )
  assert b_run.turns < DEFAULT_MAX_TURNS, (
    f"/scope B hit the max_turns cap ({DEFAULT_MAX_TURNS}) — gate kept "
    f"firing. Inspect {transcripts / 'scope-b.txt'}."
  )

  # --- Verify work-item mechanics ---
  work_items = load_all_work_items(copilot_workspace)
  assert len(work_items) == 2, (
    f"expected exactly 2 work-item files, got {len(work_items)}: "
    f"{[p.slug for p in work_items]}"
  )
  work_item_a, work_item_b = work_items  # sorted by filename = numeric prefix asc

  assert work_item_a.frontmatter.get("status") == "valid", (
    f"work item A status should be 'valid' for extends, got "
    f"{work_item_a.frontmatter.get('status')!r}"
  )
  assert work_item_b.frontmatter.get("status") == "valid", (
    f"work item B status should be 'valid' for extends, got "
    f"{work_item_b.frontmatter.get('status')!r}"
  )

  extends_value = work_item_b.frontmatter.get("extends") or []
  assert work_item_a.slug in extends_value, (
    f"work item B should extend work item A ({work_item_a.slug}); "
    f"work item B 'extends' = {extends_value!r}"
  )

  extended_by_value = work_item_a.frontmatter.get("extended_by") or []
  assert work_item_b.slug in extended_by_value, (
    f"work item A should be extended_by work item B ({work_item_b.slug}); "
    f"work item A 'extended_by' = {extended_by_value!r}"
  )

  assert not work_item_b.frontmatter.get("supersedes"), (
    f"work item B should NOT have supersedes for an extends scenario; "
    f"got {work_item_b.frontmatter.get('supersedes')!r}"
  )
  assert not work_item_a.frontmatter.get("superseded_by"), (
    f"work item A should NOT have superseded_by for an extends scenario; "
    f"got {work_item_a.frontmatter.get('superseded_by')!r}"
  )
