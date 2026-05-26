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

# OpenCode reads provider credentials via Models.dev — for the `deepseek`
# provider, `DEEPSEEK_API_KEY` is the routing key. No additional env mirror
# is required (unlike Claude Code, where DeepSeek's key has to be re-named
# into ANTHROPIC_AUTH_TOKEN so the Anthropic-compatible client picks it
# up). Model selection is passed via `--model deepseek/<id>` from
# opencode_driver.py at spawn time, not from env — recorded here as an
# empty dict so the per-agent env-setup loop in `_load_dotenv_and_route`
# stays uniform across backends.
OPENCODE_ENV_DEFAULTS: dict[str, str] = {}

# Which agent backend the workspace fixture installs and probes for.
# Default `claude` keeps the existing Claude tests running unchanged.
# Workflows targeting other backends (e.g. manual-opencode-judge.yml)
# set X_X_AGENT_KEY=opencode to flip both the `--agents <key>` value
# passed to `x-x init` and the binary the fixture skips on if missing.
VALID_AGENT_KEYS = ("claude", "opencode")
AGENT_BINARY_FOR_KEY = {
  "claude": "claude",
  "opencode": "opencode",
}
AGENT_ENV_DEFAULTS_FOR_KEY = {
  "claude": CLAUDE_ENV_DEFAULTS,
  "opencode": OPENCODE_ENV_DEFAULTS,
}

# Which `x-x init --scope` value to use when bootstrapping each test's
# workspace. Default `project` installs skills into <workspace>/.claude/skills/.
# Set X_X_INSTALL_SCOPE=user (e.g. from manual-claude-judge-user-scope.yml)
# to install skills into ~/.claude/skills/ — exercises the user-scope path
# of `x-x init`. Either way, each test gets a virgin sandboxed $HOME (see
# the `workspace` fixture), so user-scope test N never inherits ~/.claude/
# state written by test N-1; every `x-x init` starts from an empty $HOME.
VALID_SCOPES = ("project", "user")


def pytest_collection_modifyitems(items: list[Item]) -> None:
  """Filter to the active agent's tests, then run smoke before scenario.

  Each test file is named `test_<agent>_<scenario>.py` and is bound to
  exactly one backend — claude tests use the Anthropic-compatible stream
  and resolve slash commands natively; opencode tests inline SKILL.md
  content because `opencode run` does not resolve slashes today. Mixing
  them in one pytest session would have each set fail on the other's
  workspace shape, so collection deselects everything but the active
  agent's files.

  Active agent is `X_X_AGENT_KEY` (default `claude`). After filtering,
  smoke tests sort first so a wire-format / install / env regression
  fails fast instead of being masked by a scenario timeout.
  """
  active = os.environ.get("X_X_AGENT_KEY", "claude")
  selected: list[Item] = []
  deselected: list[Item] = []
  for item in items:
    if f"test_{active}_" in item.nodeid:
      selected.append(item)
    elif any(f"test_{k}_" in item.nodeid for k in VALID_AGENT_KEYS):
      deselected.append(item)
    else:
      # Unknown / agent-agnostic file — keep it in selection.
      selected.append(item)
  if deselected:
    items[:] = selected
    log(
      "conftest",
      f"deselected {len(deselected)} tests not matching agent={active!r}: "
      f"{[d.nodeid for d in deselected]}",
    )

  order_before = [item.nodeid for item in items]
  items.sort(key=lambda item: 0 if "smoke" in item.nodeid else 1)
  order_after = [item.nodeid for item in items]
  if order_before != order_after:
    log("conftest", f"reordered tests (smoke first): {order_after}")
  else:
    log("conftest", f"test order: {order_after}")


@pytest.fixture(scope="session", autouse=True)
def _load_dotenv_and_route_agent() -> None:
  """Load .env and route the active agent at DeepSeek before tests run.

  The active agent is selected by `X_X_AGENT_KEY` (default `claude`).
  Each agent's per-process env requirements are encoded in
  `AGENT_ENV_DEFAULTS_FOR_KEY` — Claude needs the `ANTHROPIC_*` block
  pointed at DeepSeek's compat shim; OpenCode picks up the deepseek
  provider directly from `DEEPSEEK_API_KEY` and needs no extra mirror.
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
      "agent backend routed through DeepSeek.",
      pytrace=False,
    )
  log(
    "conftest",
    f"DEEPSEEK_API_KEY: set (length={len(api_key)}, ...{api_key[-4:]})",
  )

  agent_key = _resolve_agent_key()
  log("conftest", f"active agent backend: {agent_key} (from X_X_AGENT_KEY)")

  # Claude routes via Anthropic-compatible env vars; mirror the DeepSeek
  # key into ANTHROPIC_AUTH_TOKEN so the Anthropic SDK in Claude Code
  # picks it up. OpenCode (and future native-provider agents) read
  # DEEPSEEK_API_KEY directly via Models.dev, so no mirror is needed.
  if agent_key == "claude" and not os.environ.get("ANTHROPIC_AUTH_TOKEN"):
    os.environ["ANTHROPIC_AUTH_TOKEN"] = api_key
    log("conftest", "mirrored DEEPSEEK_API_KEY into ANTHROPIC_AUTH_TOKEN")

  for k, v in AGENT_ENV_DEFAULTS_FOR_KEY[agent_key].items():
    if k in os.environ:
      log("conftest", f"env {k} already set: {os.environ[k]}")
    else:
      os.environ[k] = v
      log("conftest", f"env {k}={v} (default)")

  log(
    "conftest",
    f"{AGENT_BINARY_FOR_KEY[agent_key]} on PATH: "
    f"{shutil.which(AGENT_BINARY_FOR_KEY[agent_key])}",
  )
  log("conftest", f"x-x on PATH: {shutil.which('x-x')}")


def _resolve_agent_key() -> str:
  key = os.environ.get("X_X_AGENT_KEY", "claude")
  if key not in VALID_AGENT_KEYS:
    pytest.fail(
      f"X_X_AGENT_KEY={key!r} is not one of {VALID_AGENT_KEYS}",
      pytrace=False,
    )
  return key


@pytest.fixture
def workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
  """A throwaway directory with `x-x init` already run inside it.

  The init scope is read from X_X_INSTALL_SCOPE (default "project") so
  the same test suite can be driven against both
  `x-x init --scope project` (skills land under <ws>/<agent-skills-rel>/)
  and `x-x init --scope user` (skills land under $HOME/<agent-skills-rel>/).
  X_X_AGENT_KEY (default "claude") selects which agent's `--agents <key>`
  value to pass to `x-x init` and which binary to require on PATH —
  per-agent workflows (.github/workflows/manual-<agent>-*judge.yml)
  reuse this same pytest collection by flipping that env var.

  $HOME (and $USERPROFILE on Windows) is redirected to a per-test
  sandboxed directory before `x-x init` runs, so every test sees a
  virgin user-scope state. Without this, user-scope test N would
  inherit ~/.x-x/agents/, ~/.claude/skills/, and ~/.agents/skills/
  populated by test N-1, and the asymmetry between project-scope
  (fresh per test from tmp_path) and user-scope (carries state) would
  let a latent dependency on pre-install state pass undetected. The
  compiled x-x and agent CLI binaries live outside $HOME (typically
  under $(go env GOPATH)/bin and the node tool cache), so the sandbox
  does not affect binary resolution.
  """
  if shutil.which("x-x") is None:
    pytest.skip("`x-x` not on PATH — install it with `go install .` from repo root")

  agent_key = _resolve_agent_key()
  agent_bin = AGENT_BINARY_FOR_KEY[agent_key]
  if shutil.which(agent_bin) is None:
    pytest.skip(f"`{agent_bin}` not on PATH — install the {agent_key} CLI first")

  scope = os.environ.get("X_X_INSTALL_SCOPE", "project")
  if scope not in VALID_SCOPES:
    pytest.fail(
      f"X_X_INSTALL_SCOPE={scope!r} is not one of {VALID_SCOPES}",
      pytrace=False,
    )
  log("conftest", f"x-x init scope: {scope} (from X_X_INSTALL_SCOPE)")

  sandboxed_home = tmp_path / "home"
  sandboxed_home.mkdir()
  monkeypatch.setenv("HOME", str(sandboxed_home))
  # Windows resolves $HOME via USERPROFILE; set both so the sandbox
  # survives whichever variable the Go binary reads.
  monkeypatch.setenv("USERPROFILE", str(sandboxed_home))
  log("conftest", f"sandboxed $HOME: {sandboxed_home}")

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
      "--agents", agent_key,
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
    home = Path.home()
    # Mirror the on-disk path each agent's skills install to so the
    # post-install log shows what landed.
    skills_root = {
      "claude": home / ".claude" / "skills",
      "opencode": home / ".opencode" / "commands",
    }[agent_key]
    if skills_root.is_dir():
      log(
        "conftest",
        f"user-scope skills present at {skills_root}: "
        f"{sorted(p.name for p in skills_root.iterdir())}",
      )
    else:
      log("conftest", f"user-scope skills NOT found at {skills_root}")
  return ws
