# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shared pytest fixtures for the skills evals.

Two responsibilities:

1. Load `.env` (from skills-evals/ or any parent) so DEEPSEEK_API_KEY
   reaches both the judge LLM (DeepSeek directly) and the Claude Code
   backend (DeepSeek via Anthropic-compatible env vars).
2. Provide a fresh, isolated `workspace` directory per test — `x-x init`
   runs in it before any skill is invoked.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest
from _pytest.nodes import Item
from dotenv import find_dotenv, load_dotenv

# Claude Code routing for DeepSeek's Anthropic-compatible endpoint. See
# docs/internal/manually-triggered-workflows.md.
CLAUDE_ENV_DEFAULTS = {
  "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
  "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
  "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1m]",
  "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1m]",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
  "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash",
  "CLAUDE_CODE_EFFORT_LEVEL": "max",
}


def pytest_collection_modifyitems(items: list[Item]) -> None:
  """Run smoke tests before scenario tests.

  A scenario test costs 5–15 min of real DeepSeek + Claude time. The
  smoke test costs seconds. Running smoke first means a wire-format /
  install / env regression fails fast instead of being masked by a
  scenario timeout.
  """
  items.sort(key=lambda item: 0 if "smoke" in item.nodeid else 1)


@pytest.fixture(scope="session", autouse=True)
def _load_dotenv_and_route_claude() -> None:
  """Load .env and point Claude Code at DeepSeek before any test runs."""
  load_dotenv(find_dotenv(usecwd=True), override=False)
  api_key = os.environ.get("DEEPSEEK_API_KEY")
  if not api_key:
    pytest.fail(
      "DEEPSEEK_API_KEY not set. Add it to skills-evals/.env or export it "
      "before running pytest — it powers both the judge LLM and the "
      "Claude Code backend.",
      pytrace=False,
    )
  # ANTHROPIC_AUTH_TOKEN is what Claude Code reads; DEEPSEEK_API_KEY is
  # what the judge's OpenAI-compatible client reads. Same secret, two
  # env-var names.
  os.environ.setdefault("ANTHROPIC_AUTH_TOKEN", api_key)
  for k, v in CLAUDE_ENV_DEFAULTS.items():
    os.environ.setdefault(k, v)


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
  """A throwaway directory with `x-x init` already run inside it."""
  if shutil.which("x-x") is None:
    pytest.skip("`x-x` not on PATH — install it with `go install .` from repo root")
  if shutil.which("claude") is None:
    pytest.skip("`claude` not on PATH — install Claude Code first")

  ws = tmp_path / "eval-workspace"
  ws.mkdir()
  subprocess.run(["git", "init", "-q"], cwd=ws, check=True)
  subprocess.run(["git", "config", "user.email", "ci@example.com"], cwd=ws, check=True)
  subprocess.run(["git", "config", "user.name", "CI"], cwd=ws, check=True)
  subprocess.run(
    [
      "x-x", "init",
      "--scope", "project",
      "--agents", "claude",
      "--prefix-width", "4",
      "--max-plan-lines", "30",
      "--review-per", "plan",
    ],
    cwd=ws,
    check=True,
  )
  return ws
