# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the stream-json driver can talk to Claude at all.

Runs before test_claude_todo.py (alphabetical pytest order). If THIS test
fails, the failure is a wire-format / version / API-key issue — not a
skill issue. If only this test passes but test_claude_todo fails, the
issue is specific to how the skills behave under stream-json input.

The check is intentionally minimal: trivial prompt, no `x-x init`, no
skill invocation. We only assert the agent emitted at least one text
block, the run ended cleanly, and the process exited 0.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.claude_driver import drive_skill


def test_stream_json_wire_format(tmp_path: Path) -> None:
  if shutil.which("claude") is None:
    pytest.skip("`claude` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()

  run = drive_skill(
    workspace,
    "Respond with the single word: ok",
    max_turns=2,
    transcript_path=tmp_path / "transcripts" / "smoke.jsonl",
  )

  assert run.exit_code == 0, (
    f"claude exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: turns={run.turns} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — wire format may be wrong"

  text_blocks = [
    block.get("text", "")
    for event in run.transcript
    if event.get("type") == "assistant"
    for block in (event.get("message", {}) or {}).get("content", []) or []
    if isinstance(block, dict) and block.get("type") == "text"
  ]
  assert text_blocks, (
    "no assistant text blocks in transcript — stream-json wire format "
    "mismatch (envelope or required flag missing). Transcript types seen: "
    f"{sorted({e.get('type') for e in run.transcript if isinstance(e, dict)})}"
  )
