# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shared pytest fixtures for the skills evals.

1. Load `.env` (from skills-evals/ or any parent) so DEEPSEEK_API_KEY
   reaches the judge LLM (DeepSeek direct) and the active agent backend
   gets routed at whichever provider it speaks (DeepSeek-on-Anthropic for
   Claude; OpenRouter BYOK for Codex per
   `docs/internal/adding-agent-eval-backend.md`).
2. Provide a fresh, isolated `workspace` directory per test — `x-x init`
   runs in it before any skill is invoked, with `--agents` set to the
   active backend.

Which agent the run targets is controlled by X_X_AGENT (default "claude").
Each workflow file pins the env explicitly so a misconfigured run fails
loudly rather than silently picking the wrong backend.

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

VALID_AGENTS = ("claude", "codex")

# Which `x-x init --scope` value to use when bootstrapping each test's
# workspace. Default `project` installs skills into <workspace>/.claude/skills/
# (or <workspace>/.agents/skills/ for codex) so each test gets a hermetic
# skill tree. Set X_X_INSTALL_SCOPE=user (e.g. from
# manual-*-judge-user-scope.yml) to install skills into the user-scope
# tree once on the runner and reuse across every test in the session —
# exercises the user-scope path of `x-x init`.
VALID_SCOPES = ("project", "user")

CLAUDE_ENV_DEFAULTS = {
  "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
  "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
  "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1m]",
  "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1m]",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
  "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash",
  "CLAUDE_CODE_EFFORT_LEVEL": "max",
}

# Codex CLI custom providers speak OpenAI Responses protocol; DeepSeek
# native speaks Chat Completions, so direct routing is incompatible. We
# bridge through OpenRouter BYOK: OPENROUTER_API_KEY authenticates Codex
# at OpenRouter, OpenRouter forwards to DeepSeek using the user's bound
# provider key. The `~/.codex/config.toml` defining the openrouter
# provider + profile is written by the workflow (or by the dev locally)
# — the conftest does not own that file. We only verify the API key is
# present and log what we see.
CODEX_REQUIRED_ENV_KEYS = ("OPENROUTER_API_KEY",)


def pytest_collection_modifyitems(items: list[Item]) -> None:
  """Run smoke tests before scenario tests.

  A scenario test costs 5–15 min of real DeepSeek + agent time. The
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


def _active_agent() -> str:
  agent = os.environ.get("X_X_AGENT", "claude")
  if agent not in VALID_AGENTS:
    pytest.fail(
      f"X_X_AGENT={agent!r} is not one of {VALID_AGENTS}",
      pytrace=False,
    )
  return agent


@pytest.fixture(scope="session", autouse=True)
def _load_dotenv_and_route_agent() -> None:
  """Load .env and route the active agent backend at DeepSeek before any test."""
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
      "before running pytest — it powers the DeepEval judge LLM "
      "regardless of which agent backend the tests drive.",
      pytrace=False,
    )
  log(
    "conftest",
    f"DEEPSEEK_API_KEY: set (length={len(api_key)}, ...{api_key[-4:]})",
  )

  agent = _active_agent()
  log("conftest", f"X_X_AGENT={agent}")

  if agent == "claude":
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

  elif agent == "codex":
    missing = [k for k in CODEX_REQUIRED_ENV_KEYS if not os.environ.get(k)]
    if missing:
      log("conftest", f"required codex env vars MISSING: {missing} — aborting")
      pytest.fail(
        f"X_X_AGENT=codex requires env vars: {missing}. The Codex CLI "
        f"is bridged to DeepSeek via OpenRouter BYOK; provision the key "
        f"at https://openrouter.ai/keys and bind your DeepSeek key in "
        f"OpenRouter's BYOK settings. See "
        f"docs/internal/adding-agent-eval-backend.md.",
        pytrace=False,
      )
    for k in CODEX_REQUIRED_ENV_KEYS:
      v = os.environ[k]
      log("conftest", f"env {k}: set (length={len(v)}, ...{v[-4:]})")
    log("conftest", f"codex on PATH: {shutil.which('codex')}")
    codex_config = Path.home() / ".codex" / "config.toml"
    log(
      "conftest",
      f"~/.codex/config.toml: {'present' if codex_config.is_file() else 'MISSING'}",
    )

  log("conftest", f"x-x on PATH: {shutil.which('x-x')}")


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
  """A throwaway directory with `x-x init` already run inside it.

  The init scope is read from X_X_INSTALL_SCOPE (default "project") and
  the active agent from X_X_AGENT (default "claude"). The same test
  scenario file may be driven against any wired backend by changing
  these two env vars at the workflow level.
  """
  if shutil.which("x-x") is None:
    pytest.skip("`x-x` not on PATH — install it with `go install .` from repo root")

  agent = _active_agent()
  if shutil.which(agent) is None:
    pytest.skip(
      f"`{agent}` not on PATH — install it before driving the {agent} suite"
    )

  scope = os.environ.get("X_X_INSTALL_SCOPE", "project")
  if scope not in VALID_SCOPES:
    pytest.fail(
      f"X_X_INSTALL_SCOPE={scope!r} is not one of {VALID_SCOPES}",
      pytrace=False,
    )
  log("conftest", f"x-x init scope: {scope} (from X_X_INSTALL_SCOPE)")
  log("conftest", f"x-x init agents: {agent} (from X_X_AGENT)")

  ws = tmp_path / "eval-workspace"
  ws.mkdir()
  log("conftest", f"workspace: {ws}")

  for cmd in (
    ["git", "init", "-q"],
    ["git", "config", "user.email", "ci@example.com"],
    ["git", "config", "user.name", "CI"],
    [
      "x-x", "init",
      "--scope", scope,
      "--agents", agent,
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
  if scope == "user":
    # User-scope skills directory is agent-specific. Log whichever
    # plausible location exists so a missing install is visible in CI
    # logs without guessing the One True Path.
    home = Path.home()
    for candidate in (home / ".claude" / "skills", home / ".agents" / "skills"):
      if candidate.is_dir():
        log(
          "conftest",
          f"user-scope skills present at {candidate}: "
          f"{sorted(p.name for p in candidate.iterdir())}",
        )
  return ws
