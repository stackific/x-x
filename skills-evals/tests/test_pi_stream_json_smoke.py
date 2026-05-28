# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the pi_driver can talk to Pi at all.

Runs before any scenario test (alphabetical pytest order keys "smoke"
ahead via `pytest_collection_modifyitems` in conftest). If THIS test
fails, the failure is a wire-format / version / API-key / install issue
— not a skill issue. If only this passes but the scenario tests fail,
the issue is specific to skill behavior under pi.

The check is intentionally minimal: trivial prompt, no `stax init`, no
skill invocation. We only assert the run ended cleanly with exit 0 and
the wire produced at least one parseable event.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.pi_driver import drive_prompt


def test_pi_smoke(tmp_path: Path) -> None:
  if shutil.which("pi") is None:
    pytest.skip("`pi` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()

  run = drive_prompt(
    workspace,
    "Respond with the single word: ok",
    max_turns=2,
    transcript_path=tmp_path / "transcripts" / "smoke.jsonl",
  )

  assert run.exit_code == 0, (
    f"pi exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: turns={run.turns} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — wire format may be wrong"

  # pi exit 0 + at least one parsed event is enough to prove the
  # `--mode json` wire shape is what the driver expects. Asserting
  # specifically on `type: message_end` would re-fail on transient
  # DeepSeek hiccups where the model emits only `agent_start` /
  # `turn_start` before the API call drops — those aren't wire-format
  # regressions, just LLM flakiness orthogonal to what this smoke covers.
  assert run.events_received > 0, (
    "no events captured — `--mode json` did not emit any parseable "
    "lines. Types seen: "
    f"{sorted({e.get('type') for e in run.transcript if isinstance(e, dict)})}"
  )
