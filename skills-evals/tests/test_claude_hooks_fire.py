# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Verify the bundled Claude PostToolUse + Stop hooks actually fire.

`x-x init --agents=claude` deep-merges hook records into the installed
settings.json (`<workspace>/.claude/settings.json` at project scope or
`$HOME/.claude/settings.json` at user scope under the sandboxed HOME the
`workspace` fixture sets up). The JSON deep-merge plumbing is covered by
Go unit tests (init_test.go::TestInstallAgentConfig_*). This test goes
one layer deeper:

  1. patches the installed settings.json so the hook command is a
     sentinel `touch <marker>` instead of `x-x plans lint`;
  2. drives a one-shot Claude session that performs a `Write` (the
     matcher the PostToolUse hook is gated on) and then ends its turn;
  3. asserts BOTH the PostToolUse marker AND the Stop marker exist on
     disk after the session — proving Claude actually picked the hook
     records up from the path `x-x init` wrote to and executed them at
     the expected events.

A failure here after a registry / config refactor means the install
plumbing landed the JSON correctly (Go unit tests still pass) but
Claude is no longer reading hooks at the path we wrote to (or the
bundled matcher no longer matches Claude's tool name, etc.).
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from skills_evals.claude_driver import drive_skill


def _installed_settings(workspace: Path) -> Path:
  """Resolve the settings.json `x-x init` actually wrote, regardless of scope."""
  project_path = workspace / ".claude" / "settings.json"
  if project_path.is_file():
    return project_path
  user_path = Path.home() / ".claude" / "settings.json"
  if user_path.is_file():
    return user_path
  raise FileNotFoundError(
    f"no settings.json at {project_path} or {user_path} after `x-x init`"
  )


def test_claude_hooks_fire(workspace: Path, tmp_path: Path) -> None:
  if shutil.which("claude") is None:
    pytest.skip("`claude` not on PATH")

  settings = _installed_settings(workspace)
  cfg = json.loads(settings.read_text())

  # Bundled settings.json's `hooks` schema (see agents/claude/settings.json):
  #   {"hooks": {"PostToolUse": [{"matcher": "...", "hooks": [{"command": "..."}]}],
  #              "Stop":        [{"matcher": "",    "hooks": [{"command": "..."}]}]}}
  # Replace every leaf `command` under each event with a `touch <marker>`
  # sentinel so we can witness the hook firing without depending on
  # `x-x plans lint`'s exit status.
  post_marker = tmp_path / "post-tool-use.fired"
  stop_marker = tmp_path / "stop.fired"
  for entry in cfg["hooks"]["PostToolUse"]:
    for h in entry["hooks"]:
      h["command"] = f"touch {post_marker}"
  for entry in cfg["hooks"]["Stop"]:
    for h in entry["hooks"]:
      h["command"] = f"touch {stop_marker}"
  settings.write_text(json.dumps(cfg, indent=2))

  run = drive_skill(
    workspace,
    "Use the Write tool to create a file named hello.txt in the current "
    "directory containing the single line: hi. Then reply with only the "
    "word: done.",
    max_turns=5,
    transcript_path=tmp_path / "transcripts" / "claude_hooks_fire.jsonl",
  )

  assert run.exit_code == 0, (
    f"claude exited {run.exit_code}; stderr tail:\n{run.stderr_tail}"
  )
  assert (workspace / "hello.txt").is_file(), (
    "session did not perform a Write — PostToolUse cannot have fired"
  )
  assert post_marker.is_file(), (
    f"PostToolUse hook did not fire (no marker at {post_marker}). The "
    "bundled settings.json's command was replaced with a `touch` "
    "sentinel — its absence means Claude never executed the "
    "PostToolUse `Write|Edit|MultiEdit` hook for the Write action."
  )
  assert stop_marker.is_file(), (
    f"Stop hook did not fire (no marker at {stop_marker}). The session "
    "reached end-of-turn but the Stop hook's `touch` sentinel never "
    "ran — Claude is not picking up the Stop hook from the installed "
    "settings.json."
  )
