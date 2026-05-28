# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the copilot driver can talk to Copilot CLI at all.

Runs before the scenario tests (pytest_collection_modifyitems reorders
`smoke` to the front). If THIS test fails, the failure is a
binary-install / env-var / BYOK-routing issue, not a skill issue. If
only this passes but the scenario tests fail, the failure is specific
to how Copilot CLI handles `/scope` and `/ship` slash commands.

The check is intentionally minimal: trivial prompt, no `stax init`, no
slash-command invocation. We assert the agent emitted at least one line
of stdout and exited cleanly.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.copilot_driver import drive_skill


def test_copilot_stream_smoke(tmp_path: Path) -> None:
  if shutil.which("copilot") is None:
    pytest.skip("`copilot` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()

  run = drive_skill(
    workspace,
    "Respond with the single word: ok",
    transcript_path=tmp_path / "transcripts" / "smoke.txt",
  )

  assert run.exit_code == 0, (
    f"copilot exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: lines={run.events_received} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — env vars or install may be wrong"
  assert run.events_received > 0, (
    "no stdout from copilot — wire-format or auth failure. "
    f"stderr:\n{run.stderr_tail}"
  )
