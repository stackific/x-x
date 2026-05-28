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

What this means for the auto-yes mechanic the stax skills rely on:

The ship and scope skills pause at "Reply `yes` to proceed" gates. We
originally hoped `--no-ask-user` would replace the auto-yes loop, but
empirical evidence from the first manual eval run shows it's a hint,
not a hard constraint: the agent decides per-turn whether to honor the
gate. Run 26432641287 had three of four turns proceed autonomously and
one stop dead at "Reply yes" — workspace state goes wrong, downstream
turns see an empty `.stax/`.

The fix is a continuation loop modeled on the Claude driver: when one
turn ends with the "Reply yes" prompt in its captured stdout, run
`copilot --continue -p "yes"` to resume the same session and let the
agent move past the gate. `--continue` picks up the most recently
closed local session for the user (per the Copilot CLI reference) —
safe here because the eval suite runs sequentially.

Flags exercised (all documented in the reference above):
  -p <prompt>          Run the prompt non-interactively and exit.
  -s                   Silent: suppress session metadata, output only the
                       agent's response. Without -s, Copilot prints stats
                       and decoration to stdout that pollute the
                       "Reply yes" pattern match and the smoke test's
                       events_received count.
  --continue           Resume the most recently closed local session.
  -C <dir>             Override the session's saved working directory on
                       --continue. Per the May 2026 release notes,
                       --continue now resumes in the session's saved cwd
                       by default; -C makes the intended cwd explicit
                       and avoids relying on the resume default.
  --allow-all-tools    Skip per-tool permission prompts.
  --no-ask-user        Prevent the agent from asking clarifying questions
                       (best-effort — see note above).
  --add-dir <dir>      Add a directory to the allowed-paths list.
  --model <id>         Pick the model (we route to deepseek-v4-pro via the
                       Anthropic-compatible BYOK env vars below).

Routing for BYOK / DeepSeek is done via env vars set in conftest, not
flags — COPILOT_PROVIDER_TYPE=anthropic, COPILOT_PROVIDER_BASE_URL=
https://api.deepseek.com/anthropic, COPILOT_PROVIDER_API_KEY, COPILOT_MODEL.

Provider type MUST be `anthropic` (not `openai`) — DeepSeek requires
reasoning_content echo-back on subsequent requests, which Copilot CLI's
OpenAI integration does not support. The Anthropic Messages wire avoids
the issue.

Logging policy (non-negotiable, same as the Claude driver): every state
transition, every external call, every line of the agent's stderr lands
on stderr via `_logging.log`. CI logs are the only post-mortem surface.
"""

from __future__ import annotations

import os
import queue
import re
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import IO

from ._logging import log

CONFIRMATION_PATTERN = re.compile(r"reply\s+`?yes`?", re.IGNORECASE)

DEFAULT_MAX_TURNS = 10
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

  Field semantics:
    - `turns` counts Copilot invocations (initial + each `--continue` reply).
    - `yes_replies` counts how often the driver had to feed "yes" to a
      gate the agent emitted despite `--no-ask-user`.
    - `events_received` counts stdout lines across all turns.
    - `transcript` holds raw stdout lines wrapped in `{"line": "..."}`
      dicts. Turn boundaries are marked with sentinel
      `{"line": "--- turn N ---"}` entries so the post-mortem can tell
      which output came from which invocation.
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
  """Run one skill in `workspace`, auto-resuming on "Reply yes" gates.

  Turn 1: `copilot -p <initial_prompt> --allow-all-tools --no-ask-user`.
  Turns 2..max_turns: `copilot --continue -p yes --allow-all-tools
  --no-ask-user`, but only when the previous turn's stdout matched
  the "Reply yes" gate pattern. Otherwise the loop exits.
  """
  if max_turns < 1:
    raise ValueError(f"max_turns must be >= 1, got {max_turns}")

  run = SkillRun(workspace=workspace, initial_prompt=initial_prompt)
  _log_startup(workspace, initial_prompt, per_turn_timeout, max_turns)

  loop_start = time.time()
  turn_prompt = initial_prompt
  use_continue = False

  while run.turns < max_turns:
    run.transcript.append({"line": f"--- turn {run.turns + 1} ---"})
    turn_output, exit_code, stderr_tail, timed_out = _run_one_turn(
      workspace,
      turn_prompt,
      per_turn_timeout=per_turn_timeout,
      use_continue=use_continue,
    )
    for line in turn_output:
      run.transcript.append({"line": line})
    run.events_received += len(turn_output)
    run.turns += 1
    run.exit_code = exit_code
    run.stderr_tail = stderr_tail
    if timed_out:
      run.timed_out = True
      log(
        "driver",
        f"turn {run.turns} TIMED OUT — abandoning continuation loop",
      )
      break
    if exit_code != 0:
      log(
        "driver",
        f"turn {run.turns} exited {exit_code} — abandoning continuation loop",
      )
      break

    last_text = "\n".join(turn_output[-40:])
    if not _asks_for_confirmation(last_text):
      log(
        "driver",
        f"turn {run.turns} ended without 'Reply yes' gate — session done",
      )
      run.completed = True
      break

    log(
      "driver",
      f"turn {run.turns} ended at 'Reply yes' gate — resuming with --continue",
    )
    run.yes_replies += 1
    turn_prompt = "yes"
    use_continue = True
  else:
    # while-else fires when the loop's condition (turns < max_turns)
    # becomes false without a break. We hit the turn cap while the agent
    # was still gating — surface that loudly, not silently as "completed".
    log(
      "driver",
      f"hit max_turns={max_turns} with the gate still firing — stopping",
    )

  log(
    "driver",
    f"drive_skill done: turns={run.turns} yes_replies={run.yes_replies} "
    f"lines={run.events_received} exit_code={run.exit_code} "
    f"completed={run.completed} timed_out={run.timed_out} "
    f"elapsed={time.time() - loop_start:.1f}s",
  )

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  return run


def _run_one_turn(
  workspace: Path,
  prompt: str,
  *,
  per_turn_timeout: float,
  use_continue: bool,
) -> tuple[list[str], int | None, str, bool]:
  """Spawn one `copilot` invocation and return (stdout_lines, exit_code,
  stderr_tail, timed_out).

  Each call is a fresh subprocess — Copilot CLI is single-shot per
  invocation. `use_continue=True` adds `--continue` so the process
  resumes the previous session's conversation history instead of
  starting fresh.
  """
  cmd = ["copilot"]
  if use_continue:
    # -C pins the resumed session's working directory to our workspace.
    # Without it, --continue's "resume in saved cwd" default applies and
    # can land in whatever dir the original session was spawned from.
    cmd.extend(["--continue", "-C", str(workspace)])
  cmd.extend([
    "-p", prompt,
    "-s",
    "--allow-all-tools",
    "--no-ask-user",
    "--add-dir", str(workspace),
  ])
  model = os.environ.get("COPILOT_MODEL")
  if model:
    cmd.extend(["--model", model])

  log("driver", f"spawn: {' '.join(cmd[:3])} ... (--continue={use_continue})")
  log("driver", f"prompt: {_brief(prompt, 200)}")
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

  stdout_lines: list[str] = []
  turn_start = time.time()
  timed_out = False

  try:
    while True:
      try:
        line = out_q.get(timeout=per_turn_timeout)
      except queue.Empty:
        timed_out = True
        log(
          "driver",
          f"TIMEOUT after {per_turn_timeout}s waiting for next stdout line "
          f"(lines this turn: {len(stdout_lines)}, "
          f"elapsed: {time.time() - turn_start:.1f}s)",
        )
        break

      if line is None:
        log(
          "driver",
          f"stdout EOF (copilot exited); lines this turn: {len(stdout_lines)}",
        )
        break

      stdout_lines.append(line)
      if line.strip():
        log("driver", f"stdout #{len(stdout_lines)}: {_brief(line, 200)}")
  finally:
    try:
      proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
      log("driver", "copilot did not exit within 15s; killing")
      proc.kill()
      proc.wait(timeout=5)

  stderr_tail = "\n".join(err_lines[-40:])
  log(
    "driver",
    f"turn done: exit={proc.returncode} lines={len(stdout_lines)} "
    f"timed_out={timed_out} elapsed={time.time() - turn_start:.1f}s",
  )
  return stdout_lines, proc.returncode, stderr_tail, timed_out


def _log_startup(
  workspace: Path,
  initial_prompt: str,
  per_turn_timeout: float,
  max_turns: int,
) -> None:
  log("driver", f"drive_skill called: workspace={workspace}")
  log("driver", f"initial_prompt: {_brief(initial_prompt, 200)}")
  log(
    "driver",
    f"per_turn_timeout={per_turn_timeout}s max_turns={max_turns}",
  )

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


def _asks_for_confirmation(text: str) -> bool:
  return bool(CONFIRMATION_PATTERN.search(text or ""))


def _brief(text: str, limit: int = 140) -> str:
  collapsed = " ".join((text or "").split())
  return collapsed if len(collapsed) <= limit else collapsed[: limit - 1] + "…"
