# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shared pytest fixtures for the skills evals.

1. Load `.env` (from skills-evals/ or any parent) so DEEPSEEK_API_KEY
   reaches the judge LLM (DeepSeek directly) AND every supported agent:
   - Claude Code via the Anthropic-compatible endpoint (env vars).
   - Kilo Code via the openai-compatible endpoint (per-workspace
     `kilo.json` with `{env:DEEPSEEK_API_KEY}` substitution).
2. Provide a fresh, isolated `workspace` directory per test — `x-x init`
   runs in it with `--agents <X_X_AGENT_UNDER_TEST>` (default "claude").
   For Kilo, the fixture additionally writes a `kilo.json` pointing at
   DeepSeek's openai-compatible endpoint.

Everything logs verbosely. Silence is a bug.
"""

from __future__ import annotations

import json
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

# Kilo's CLI routes via a config file rather than environment alone for
# custom OpenAI-compatible endpoints; these env vars cover the cases where
# kilo bypasses the config (org selection, model override). The real
# routing lives in KILO_WORKSPACE_CONFIG below. Names per
# https://kilo.ai/docs/code-with-ai/platforms/cli.
KILO_ENV_DEFAULTS = {
  "KILO_PROVIDER": "openai-compatible",
  "KILOCODE_MODEL": "openai-compatible/deepseek-v4-pro",
}

# Provider stanza written into each Kilo test workspace. The `{env:...}`
# substitution is the documented Kilo pattern for keeping secrets out of
# config; `apiKey` resolves at agent startup against the live process env.
KILO_WORKSPACE_CONFIG = {
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

# Which `x-x init --scope` value to use when bootstrapping each test's
# workspace. Default `project` installs skills into <workspace>/<agent>/skills/
# so each test gets a hermetic skill tree. Set X_X_INSTALL_SCOPE=user (e.g.
# from manual-*-judge-user-scope.yml) to install skills into the user-home
# tree once on the runner and reuse across every test in the session —
# exercises the user-scope path of `x-x init`.
VALID_SCOPES = ("project", "user")

# Which agent CLI the workspace is configured for. The kilo workflow sets
# X_X_AGENT_UNDER_TEST=kilo; the claude workflow leaves it at the default.
# Drives the `--agents` flag passed to `x-x init` and whether a per-workspace
# kilo.json is written. Tests stay agnostic — each imports its backend's
# driver explicitly.
VALID_AGENTS_UNDER_TEST = ("claude", "kilo")


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
def _load_dotenv_and_route_agents() -> None:
  """Load .env and point every supported agent at DeepSeek before tests run.

  Sets defaults for both the Claude and the Kilo routing surfaces — the
  vars for the agent that isn't under test are harmless to set (each CLI
  ignores the other's namespace).
  """
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
      "before running pytest — it powers both the judge LLM and every "
      "supported agent backend.",
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

  # Kilo doesn't read DEEPSEEK_API_KEY itself; the workspace kilo.json
  # substitutes `{env:DEEPSEEK_API_KEY}` at agent startup, but we ALSO
  # mirror it into KILO_API_KEY as a belt-and-suspenders for the generic
  # provider field documented at kilo.ai/docs/code-with-ai/platforms/cli.
  if not os.environ.get("KILO_API_KEY"):
    os.environ["KILO_API_KEY"] = api_key
    log("conftest", "mirrored DEEPSEEK_API_KEY into KILO_API_KEY")
  else:
    log("conftest", "KILO_API_KEY already set; leaving as-is")

  for k, v in CLAUDE_ENV_DEFAULTS.items():
    if k in os.environ:
      log("conftest", f"env {k} already set: {os.environ[k]}")
    else:
      os.environ[k] = v
      log("conftest", f"env {k}={v} (default)")

  for k, v in KILO_ENV_DEFAULTS.items():
    if k in os.environ:
      log("conftest", f"env {k} already set: {os.environ[k]}")
    else:
      os.environ[k] = v
      log("conftest", f"env {k}={v} (default)")

  log("conftest", f"claude on PATH: {shutil.which('claude')}")
  log("conftest", f"kilo on PATH: {shutil.which('kilo')}")
  log("conftest", f"x-x on PATH: {shutil.which('x-x')}")


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
  """A throwaway directory with `x-x init` already run inside it.

  The init scope is read from X_X_INSTALL_SCOPE (default "project"). The
  agent under test is read from X_X_AGENT_UNDER_TEST (default "claude").
  Together they let the same test suite drive any supported backend at
  either scope without code changes — workflows set the env vars; the
  fixture does the rest.

  For Kilo, the fixture additionally writes a `kilo.json` into the
  workspace declaring an openai-compatible provider pointing at
  api.deepseek.com/v1 with `{env:DEEPSEEK_API_KEY}` substitution. Without
  this file, kilo has no documented way to route at a custom OpenAI-compat
  endpoint from env vars alone.
  """
  if shutil.which("x-x") is None:
    pytest.skip("`x-x` not on PATH — install it with `go install .` from repo root")

  agent = os.environ.get("X_X_AGENT_UNDER_TEST", "claude")
  if agent not in VALID_AGENTS_UNDER_TEST:
    pytest.fail(
      f"X_X_AGENT_UNDER_TEST={agent!r} is not one of {VALID_AGENTS_UNDER_TEST}",
      pytrace=False,
    )
  if shutil.which(agent) is None:
    pytest.skip(f"`{agent}` not on PATH — install the {agent} CLI first")
  log("conftest", f"x-x init agent: {agent} (from X_X_AGENT_UNDER_TEST)")

  scope = os.environ.get("X_X_INSTALL_SCOPE", "project")
  if scope not in VALID_SCOPES:
    pytest.fail(
      f"X_X_INSTALL_SCOPE={scope!r} is not one of {VALID_SCOPES}",
      pytrace=False,
    )
  log("conftest", f"x-x init scope: {scope} (from X_X_INSTALL_SCOPE)")

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

  if agent == "kilo":
    kilo_config_path = ws / "kilo.json"
    kilo_config_path.write_text(json.dumps(KILO_WORKSPACE_CONFIG, indent=2))
    log("conftest", f"wrote {kilo_config_path} (DeepSeek via openai-compatible)")

  log("conftest", f"workspace ready: {sorted(p.name for p in ws.iterdir())}")
  if scope == "user":
    home = Path.home()
    skills_dirs = {
      "claude": home / ".claude" / "skills",
      "kilo": home / ".kilo" / "skills",
    }
    user_skills = skills_dirs.get(agent)
    if user_skills is not None and user_skills.is_dir():
      log(
        "conftest",
        f"user-scope skills present at {user_skills}: "
        f"{sorted(p.name for p in user_skills.iterdir())}",
      )
    elif user_skills is not None:
      log("conftest", f"user-scope skills NOT found at {user_skills}")
  return ws
