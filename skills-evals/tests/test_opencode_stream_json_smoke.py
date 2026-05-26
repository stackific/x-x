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

from skills_evals.opencode_driver import drive_skill


def test_opencode_smoke(tmp_path: Path) -> None:
  if shutil.which("opencode") is None:
    pytest.skip("`opencode` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()

  run = drive_skill(
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

  # We don't pin a specific event shape (OpenCode's `--format json`
  # protocol is sparsely documented), but the transcript must contain
  # at least one non-empty event so we know parsing wasn't silently
  # dropping the stream. The `_brief`-summarized event log on stderr
  # is the primary debugging surface; this assertion just guards
  # against a fully empty stream which would otherwise pass silently.
  assert run.events_received > 0, (
    "no events captured from opencode — wire format mismatch or "
    "`--format json` not emitted. Check the driver stderr log."
  )
