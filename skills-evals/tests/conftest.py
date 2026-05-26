# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shared pytest fixtures for the skills evals.

1. Load `.env` (from skills-evals/ or any parent) so DEEPSEEK_API_KEY
   reaches both the judge LLM (DeepSeek directly) and the Claude Code
   backend (DeepSeek via Anthropic-compatible env vars).
2. Provide a fresh, isolated `workspace` directory per test — `x-x init`
   runs in it before any skill is invoked.

Everything logs verbosely. Silence is a bug.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from _pytest.nodes import Item
from dotenv import find_dotenv, load_dotenv

from skills_evals._logging import log

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
  order_before = [item.nodeid for item in items]
  items.sort(key=lambda item: 0 if "smoke" in item.nodeid else 1)
  order_after = [item.nodeid for item in items]
  if order_before != order_after:
    log("conftest", f"reordered tests (smoke first): {order_after}")
  else:
    log("conftest", f"test order: {order_after}")


@pytest.fixture(scope="session", autouse=True)
def _load_dotenv_and_route_claude() -> None:
  """Load .env and point Claude Code at DeepSeek before any test runs."""
  log("conftest", f"python={sys.version.split()[0]} platform={sys.platform}")

  env_path = find_dotenv(usecwd=True)
  log("conftest", f".env search result: {env_path or '(none)'}")
  load_dotenv(env_path, override=False)
  if env_path:
    log("conftest", f"loaded .env from {env_path}")

  api_key = os.environ.get("DEEPSEEK_API_KEY")
  if not api_key:
    log("conftest", "DEEPSEEK_API_KEY MISSING — aborting")
    pytest.fail(
      "DEEPSEEK_API_KEY not set. Add it to skills-evals/.env or export it "
      "before running pytest — it powers both the judge LLM and the "
      "Claude Code backend.",
      pytrace=False,
    )
  log(
    "conftest",
    f"DEEPSEEK_API_KEY: set (length={len(api_key)}, ...{api_key[-4:]})",
  )

  if not os.environ.get("ANTHROPIC_AUTH_TOKEN"):
    os.environ["ANTHROPIC_AUTH_TOKEN"] = api_key
    log("conftest", "mirrored DEEPSEEK_API_KEY into ANTHROPIC_AUTH_TOKEN")
  else:
    log("conftest", "ANTHROPIC_AUTH_TOKEN already set; leaving as-is")

  for k, v in CLAUDE_ENV_DEFAULTS.items():
    if k in os.environ:
      log("conftest", f"env {k} already set: {os.environ[k]}")
    else:
      os.environ[k] = v
      log("conftest", f"env {k}={v} (default)")

  log("conftest", f"claude on PATH: {shutil.which('claude')}")
  log("conftest", f"x-x on PATH: {shutil.which('x-x')}")


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
  """A throwaway directory with `x-x init` already run inside it."""
  if shutil.which("x-x") is None:
    pytest.skip("`x-x` not on PATH — install it with `go install .` from repo root")
  if shutil.which("claude") is None:
    pytest.skip("`claude` not on PATH — install Claude Code first")

  ws = tmp_path / "eval-workspace"
  ws.mkdir()
  log("conftest", f"workspace: {ws}")

  for cmd in (
    ["git", "init", "-q"],
    ["git", "config", "user.email", "ci@example.com"],
    ["git", "config", "user.name", "CI"],
    [
      "x-x", "init",
      "--scope", "project",
      "--agents", "claude",
      "--prefix-width", "4",
      "--max-plan-lines", "30",
      "--review-per", "plan",
    ],
  ):
    log("conftest", f"run: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=ws, capture_output=True, text=True)
    if result.stdout.strip():
      for line in result.stdout.rstrip().splitlines():
        log("conftest", f"  stdout: {line}")
    if result.stderr.strip():
      for line in result.stderr.rstrip().splitlines():
        log("conftest", f"  stderr: {line}")
    log("conftest", f"  exit={result.returncode}")
    if result.returncode != 0:
      pytest.fail(
        f"workspace setup failed: {' '.join(cmd)} exited {result.returncode}",
        pytrace=False,
      )

  log("conftest", f"workspace ready: {sorted(p.name for p in ws.iterdir())}")
  return ws
