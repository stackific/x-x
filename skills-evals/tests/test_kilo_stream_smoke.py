# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the kilo driver can talk to Kilo Code at all.

Runs before the scenario tests (pytest collection-modify hook puts smokes
first). If THIS test fails, the failure is a wire-format / version /
provider-config issue — not a skill issue. If only this test passes but
test_kilo_todo fails, the issue is specific to how the skills behave when
driven through Kilo against DeepSeek's openai-compatible endpoint.

The check is intentionally minimal: trivial prompt, no `x-x init` (the
workspace fixture supplies that), no skill invocation. We only assert kilo
emitted at least one piece of assistant text, the run ended cleanly, and
the process exited 0.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.kilo_driver import drive_skill


def test_kilo_stream_wire_format(workspace: Path, tmp_path: Path) -> None:
  if shutil.which("kilo") is None:
    pytest.skip("`kilo` not on PATH")

  run = drive_skill(
    workspace,
    "Respond with the single word: ok",
    max_turns=2,
    transcript_path=tmp_path / "transcripts" / "kilo-smoke.jsonl",
  )

  assert run.exit_code == 0, (
    f"kilo exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: turns={run.turns} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — wire format may be wrong"

  assert run.transcript, (
    "kilo emitted zero JSON events on --format json. Either the flag is "
    "not honored on this version, or events go to stderr only. stderr:\n"
    f"{run.stderr_tail}"
  )
