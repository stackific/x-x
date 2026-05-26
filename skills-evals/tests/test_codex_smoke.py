# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shape-check that the codex driver can talk to Codex CLI at all.

Runs before the codex scenario tests (smoke-first ordering in conftest).
If THIS test fails the failure is a wire-format / version / API-key /
OpenRouter-routing issue — not a skill issue. If only this test passes
but a scenario fails, the issue is specific to how the skills behave
when driven by Codex.

The check is intentionally minimal: trivial prompt, no `x-x init`, no
skill invocation. We assert the agent emitted at least one event, the
run reached `turn.completed`, and codex exited 0.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from skills_evals.codex_driver import drive_skill


def test_codex_wire_format(tmp_path: Path) -> None:
  if shutil.which("codex") is None:
    pytest.skip("`codex` not on PATH")

  workspace = tmp_path / "bare"
  workspace.mkdir()

  run = drive_skill(
    workspace,
    "Respond with the single word: ok",
    max_turns=2,
    transcript_path=tmp_path / "transcripts" / "smoke.jsonl",
  )

  assert run.exit_code == 0, (
    f"codex exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert run.completed, (
    f"smoke test didn't complete: turns={run.turns} "
    f"timed_out={run.timed_out} stderr:\n{run.stderr_tail}"
  )
  assert not run.timed_out, "smoke test timed out — wire format may be wrong"
  assert run.events_received > 0, (
    "no events parsed off codex stdout — `codex exec --json` may have "
    "changed shape, or routing failed silently. Inspect transcript."
  )
  assert run.session_id, (
    "no session_id captured — the resume mechanic for multi-turn skills "
    "will not work. Check `thread.started` event shape in the transcript."
  )
