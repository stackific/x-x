# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive a GitHub Copilot CLI session non-interactively for one skill.

GitHub Copilot CLI's non-interactive mode is single-shot: `copilot -p
"<prompt>"` runs the prompt to completion and exits. Unlike Claude Code's
`--input-format stream-json` (which keeps one process alive for the whole
multi-turn session), there is no documented stay-alive-and-stream protocol
for Copilot CLI as of May 2026 — see the public reference at
docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference
and the issue tracking missing stream output in CI:
github.com/github/copilot-cli/issues/1181.

What this means for the auto-yes mechanic the x-x skills rely on:

The x-x and x-plan skills are designed to pause and ask the user to "Reply
yes to proceed" at gate points. Claude's driver handles that with a
JSON-Lines auto-yes loop on a single long-lived process. Copilot CLI ships
the equivalent as a single command-line flag: `--no-ask-user` prevents the
agent from pausing for clarification, and `--allow-all-tools` waives tool
permission prompts. With both flags set, Copilot proceeds through the
skill without pausing — replicating the "always reply yes" behavior in one
invocation instead of a turn loop.

Flags exercised here (all documented in the reference above):
  -p <prompt>          Run the prompt non-interactively and exit.
  --allow-all-tools    Skip per-tool permission prompts.
  --no-ask-user        Prevent the agent from asking clarifying questions.
  --add-dir <dir>      Add a directory to the allowed-paths list.
  --model <id>         Pick the model (we route to deepseek-v4-pro via the
                       Anthropic-compatible BYOK env vars below).

Routing for BYOK / DeepSeek is done via env vars set in conftest, not
flags — COPILOT_PROVIDER_TYPE=anthropic, COPILOT_PROVIDER_BASE_URL=
https://api.deepseek.com/anthropic, COPILOT_PROVIDER_API_KEY, COPILOT_MODEL.

Known gaps to discover in CI (do not paper over — fail loudly per the
agent-eval recipe in docs/internal/adding-agent-eval-backend.md):

1. Skill loading. `x-x init --agents` does not yet accept `copilot` (the
   `agentTargets` registry in constants.go ships claude + codex only).
   Tests in this suite call `x-x init --agents claude`, which writes skills
   to `.claude/skills/`. Whether Copilot CLI discovers slash commands
   under that path, under its own convention, or not at all, is the first
   thing the workflow run will reveal. The smoke test does not depend on
   skills and is the canary.

2. Wire format. There is no public `--output-format stream-json` analogue.
   We capture stdout as the transcript (plain text) and log every line.
   If a future Copilot version adds structured output, swap the line
   reader for a JSON parser.

3. Multi-turn. Each skill invocation is its own process. The workspace
   filesystem (plan files, produced artifacts) is the only state that
   carries between turns. That matches the x-x flow — `/x-plan` writes
   files; `/x-x` reads them — but it does mean we cannot pass intermediate
   conversation context between calls.

Logging policy (non-negotiable, same as the Claude driver): every state
transition, every external call, every line of the agent's stderr lands
on stderr via `_logging.log`. CI logs are the only post-mortem surface.
"""

from __future__ import annotations

import os
import queue
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import IO

from ._logging import log

DEFAULT_MAX_TURNS = 1
DEFAULT_PER_TURN_TIMEOUT_S = 600.0

# Echoed at driver startup so CI logs show exactly which backend Copilot
# is routed to. Non-secret values are printed in full; secrets are masked.
ECHOED_ENV_KEYS = (
  "COPILOT_PROVIDER_TYPE",
  "COPILOT_PROVIDER_BASE_URL",
  "COPILOT_MODEL",
  "COPILOT_PROVIDER_MAX_PROMPT_TOKENS",
  "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS",
  "COPILOT_OFFLINE",
)
SECRET_ENV_KEYS = (
  "COPILOT_PROVIDER_API_KEY",
  "DEEPSEEK_API_KEY",
  "COPILOT_GITHUB_TOKEN",
  "GH_TOKEN",
)


@dataclass
class SkillRun:
  """Mirror of claude_driver.SkillRun for cross-driver test parity.

  Field semantics differ slightly because the wire is different:
    - `turns` is always 0 or 1 — Copilot CLI is single-shot per invocation.
    - `yes_replies` is always 0 — `--no-ask-user` replaces the auto-yes
      loop with a single flag.
    - `events_received` counts stdout lines (plain text), not JSON events.
    - `transcript` holds raw stdout lines wrapped in `{"line": "..."}`
      dicts so callers that walk the transcript get the same shape as
      Claude's JSONL stream.
  """

  workspace: Path
  initial_prompt: str
  transcript: list[dict] = field(default_factory=list)
  turns: int = 0
  yes_replies: int = 0
  events_received: int = 0
  completed: bool = False
  timed_out: bool = False
  exit_code: int | None = None
  stderr_tail: str = ""

  def save_transcript(self, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
      for entry in self.transcript:
        line = entry.get("line", "")
        f.write(line + "\n")


def drive_skill(
  workspace: Path,
  initial_prompt: str,
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
) -> SkillRun:
  """Run one skill in `workspace` via a single `copilot -p` invocation.

  `max_turns` is accepted for signature parity with claude_driver and
  ignored beyond a sanity assertion — Copilot CLI is single-shot.
  """
  if max_turns < 1:
    raise ValueError(f"max_turns must be >= 1, got {max_turns}")

  run = SkillRun(workspace=workspace, initial_prompt=initial_prompt)
  _log_startup(workspace, initial_prompt, per_turn_timeout)

  cmd = [
    "copilot",
    "-p", initial_prompt,
    "--allow-all-tools",
    "--no-ask-user",
    "--add-dir", str(workspace),
  ]
  model = os.environ.get("COPILOT_MODEL")
  if model:
    cmd.extend(["--model", model])

  log("driver", f"spawn: {' '.join(cmd)}")
  log("driver", f"cwd: {workspace}")

  proc = subprocess.Popen(
    cmd,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    cwd=str(workspace),
    text=True,
    bufsize=1,
  )
  log("driver", f"spawned pid={proc.pid}")

  out_q: queue.Queue[str | None] = queue.Queue()
  err_lines: list[str] = []
  threading.Thread(
    target=_pump_to_queue, args=(proc.stdout, out_q), daemon=True
  ).start()
  threading.Thread(
    target=_pump_stderr_live, args=(proc.stderr, err_lines), daemon=True
  ).start()

  loop_start = time.time()

  try:
    while True:
      try:
        line = out_q.get(timeout=per_turn_timeout)
      except queue.Empty:
        run.timed_out = True
        log(
          "driver",
          f"TIMEOUT after {per_turn_timeout}s waiting for next stdout line "
          f"(lines seen: {run.events_received}, "
          f"elapsed since spawn: {time.time() - loop_start:.1f}s)",
        )
        break

      if line is None:
        log(
          "driver",
          f"stdout EOF (copilot exited); lines seen: {run.events_received}",
        )
        run.completed = True
        run.turns = 1
        break

      run.transcript.append({"line": line})
      run.events_received += 1
      if line.strip():
        log("driver", f"stdout #{run.events_received}: {_brief(line, 200)}")

  finally:
    try:
      proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
      log("driver", "copilot did not exit within 15s; killing")
      proc.kill()
      proc.wait(timeout=5)
    run.exit_code = proc.returncode
    run.stderr_tail = "\n".join(err_lines[-40:])
    log(
      "driver",
      f"copilot exited code={run.exit_code} "
      f"lines={run.events_received} "
      f"completed={run.completed} timed_out={run.timed_out} "
      f"elapsed={time.time() - loop_start:.1f}s",
    )

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  return run


def _log_startup(
  workspace: Path,
  initial_prompt: str,
  per_turn_timeout: float,
) -> None:
  log("driver", f"drive_skill called: workspace={workspace}")
  log("driver", f"initial_prompt: {_brief(initial_prompt, 200)}")
  log("driver", f"per_turn_timeout={per_turn_timeout}s")

  copilot_path = shutil.which("copilot")
  log("driver", f"copilot on PATH: {copilot_path}")
  if copilot_path:
    try:
      out = subprocess.run(
        ["copilot", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"copilot --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"copilot --version failed: {e}")

  for key in ECHOED_ENV_KEYS:
    log("driver", f"env {key}={os.environ.get(key, '(unset)')}")
  for key in SECRET_ENV_KEYS:
    val = os.environ.get(key)
    if val:
      log("driver", f"env {key}=set (length={len(val)}, ...{val[-4:]})")
    else:
      log("driver", f"env {key}=MISSING")


def _pump_to_queue(stream: IO[str], q: queue.Queue[str | None]) -> None:
  try:
    for line in stream:
      q.put(line.rstrip("\n"))
  finally:
    q.put(None)


def _pump_stderr_live(stream: IO[str], sink: list[str]) -> None:
  for line in stream:
    s = line.rstrip("\n")
    sink.append(s)
    if s.strip():
      log("driver", f"stderr: {s}")


def _brief(text: str, limit: int = 140) -> str:
  collapsed = " ".join((text or "").split())
  return collapsed if len(collapsed) <= limit else collapsed[: limit - 1] + "…"
