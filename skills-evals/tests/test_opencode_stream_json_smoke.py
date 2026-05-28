# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the opencode_driver can talk to OpenCode at all.

Runs before any scenario test (alphabetical pytest order keys "smoke"
ahead via `pytest_collection_modifyitems` in conftest). If THIS test
fails, the failure is a wire-format / version / API-key / install issue
— not a skill issue. If only this passes but the scenario tests fail,
the issue is specific to skill behavior under opencode.

The check is intentionally minimal: trivial prompt, no `x-x init`, no
skill invocation. We only assert the agent emitted some text, the run
ended cleanly, and the process exited 0.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.opencode_driver import drive_prompt


def test_opencode_smoke(tmp_path: Path) -> None:
  if shutil.which("opencode") is None:
    pytest.skip("`opencode` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()

  run = drive_prompt(
    workspace,
    "Respond with the single word: ok",
    max_turns=2,
    transcript_path=tmp_path / "transcripts" / "smoke.jsonl",
  )

  assert run.exit_code == 0, (
    f"opencode exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: turns={run.turns} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — wire format may be wrong"

  text_events = [e for e in run.transcript if e.get("type") == "text"]
  assert text_events, (
    "no `type: text` events captured — `--format json` did not emit the "
    "shape the driver expects. Types seen: "
    f"{sorted({e.get('type') for e in run.transcript if isinstance(e, dict)})}"
  )
