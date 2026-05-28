# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the omp driver can talk to omp (oh-my-pi) at all.

Runs before the scenario tests (`pytest_collection_modifyitems` reorders
`smoke` to the front). If THIS test fails, the failure is a binary-install
/ env-var / Models.dev DeepSeek-routing issue, not a skill issue. If only
this passes but the scenario tests fail, the failure is specific to how
omp handles the `/skill:scope` and `/skill:stax` slash-command forms.

The check is intentionally minimal: trivial prompt, no `stax init`, no
slash-command invocation. We assert the agent emitted at least one
parseable JSON event and exited cleanly.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.omp_driver import drive_skill


def test_omp_stream_smoke(tmp_path: Path) -> None:
  if shutil.which("omp") is None:
    pytest.skip("`omp` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()

  run = drive_skill(
    workspace,
    "Respond with the single word: ok",
    max_turns=2,
    transcript_path=tmp_path / "transcripts" / "smoke.jsonl",
  )

  assert run.exit_code == 0, (
    f"omp exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: turns={run.turns} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — env vars or install may be wrong"

  # `--mode json` should produce at least one parseable event. Asserting
  # specifically on a text event would re-fail on transient DeepSeek
  # hiccups where the model emits only a step/tool event before the
  # request drops — those aren't wire-format regressions, just LLM
  # flakiness orthogonal to what the smoke covers.
  assert run.events_received > 0, (
    "no events captured — `--mode json` did not emit any parseable lines. "
    "Types seen: "
    f"{sorted({e.get('type') for e in run.transcript if isinstance(e, dict)})}"
    f"\nstderr:\n{run.stderr_tail}"
  )
