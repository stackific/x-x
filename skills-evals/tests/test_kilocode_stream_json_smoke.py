# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the kilocode_driver can talk to Kilo Code at all.

Runs before any scenario test (alphabetical pytest order keys "smoke"
ahead via `pytest_collection_modifyitems` in conftest). If THIS test
fails, the failure is a wire-format / version / API-key / install issue
— not a skill issue. If only this passes but the scenario tests fail,
the issue is specific to skill behavior under Kilo Code.

The check is intentionally minimal: trivial prompt, no `x-x init`, no
skill invocation. We write a workspace-local `kilo.json` so routing
works, then only assert the run ended cleanly with exit 0 and the wire
produced at least one parseable event.

The kilo.json mirrors the workspace fixture's KILOCODE_WORKSPACE_CONFIG
because the smoke test does NOT depend on the workspace fixture
(intentionally — it tests the driver in isolation from `x-x init` so
a routing regression doesn't masquerade as a skill-discovery
regression).
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from skills_evals.kilocode_driver import drive_prompt

# Inline copy of conftest.KILOCODE_WORKSPACE_CONFIG. Duplicating ~12 lines
# of JSON here is cheaper than importing from conftest (pytest discourages
# importing from conftest modules; the smoke test is meant to be runnable
# standalone for ad-hoc debugging anyway).
SMOKE_KILO_CONFIG = {
  "$schema": "https://app.kilo.ai/config.json",
  "model": "openai-compatible/deepseek-v4-pro",
  "provider": {
    "openai-compatible": {
      "options": {
        "apiKey": "{env:DEEPSEEK_API_KEY}",
        "baseURL": "https://api.deepseek.com/v1",
      },
      "models": {
        "deepseek-v4-pro": {
          "name": "DeepSeek V4 Pro",
          "tool_call": True,
          "limit": {"context": 128000, "output": 8192},
        },
      },
    },
  },
}


def test_kilocode_smoke(tmp_path: Path) -> None:
  if shutil.which("kilo") is None:
    pytest.skip("`kilo` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()
  (workspace / "kilo.json").write_text(json.dumps(SMOKE_KILO_CONFIG, indent=2))

  run = drive_prompt(
    workspace,
    "Respond with the single word: ok",
    max_turns=2,
    transcript_path=tmp_path / "transcripts" / "smoke.jsonl",
  )

  assert run.exit_code == 0, (
    f"kilo exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: turns={run.turns} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — wire format may be wrong"

  # kilo exit 0 + at least one parsed event is enough to prove the
  # `--format json` wire shape is what the driver expects. Asserting
  # specifically on `type: text` would re-fail on transient DeepSeek
  # hiccups where the model emits only a `step_start` before the API
  # call drops — those aren't wire-format regressions, just LLM
  # flakiness that's orthogonal to what this smoke covers.
  assert run.events_received > 0, (
    "no events captured — `--format json` did not emit any parseable "
    "lines. Types seen: "
    f"{sorted({e.get('type') for e in run.transcript if isinstance(e, dict)})}"
  )
