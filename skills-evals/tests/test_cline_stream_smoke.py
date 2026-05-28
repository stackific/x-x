# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the cline driver can talk to Cline CLI at all.

Runs before the scenario tests (pytest_collection_modifyitems reorders
`smoke` to the front). If THIS test fails, the failure is a
binary-install / env-var / BYOK-routing / auth-state issue, not a skill
issue. If only this passes but the scenario tests fail, the failure is
specific to how Cline CLI handles the inlined SKILL.md prompt.

The check is intentionally minimal: trivial prompt, no `x-x init`, no
SKILL inlining. We assert cline emitted at least one NDJSON event and
exited cleanly.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.cline_driver import drive_prompt


def test_cline_smoke(tmp_path: Path) -> None:
  if shutil.which("cline") is None:
    pytest.skip("`cline` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()

  run = drive_prompt(
    workspace,
    "Respond with the single word: ok",
    max_turns=2,
    transcript_path=tmp_path / "transcripts" / "smoke.jsonl",
  )

  assert run.exit_code == 0, (
    f"cline exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: turns={run.turns} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — wire format may be wrong"

  # cline exit 0 + at least one parsed event is enough to prove the
  # `--json` wire shape is what the driver expects. Asserting
  # specifically on say/text content would re-fail on transient DeepSeek
  # hiccups where the model emits only a tool-use envelope before the
  # API call drops — those aren't wire-format regressions.
  assert run.events_received > 0, (
    "no events captured — `--json` did not emit any parseable lines. "
    "Types seen: "
    f"{sorted({e.get('type') for e in run.transcript if isinstance(e, dict)})}"
  )
