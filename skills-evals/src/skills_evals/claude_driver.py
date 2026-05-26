# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive a Claude Code session non-interactively with auto-yes replies.

The x-x skills (`/x-plan`, `/x-x`) routinely pause and ask the user to
`Reply yes to proceed`. A bare `claude -p "/x-plan ..."` invocation is
one-shot — it gets the question, exits without answering, and the skill
aborts before doing real work.

This module spawns `claude` in stream-json mode (multi-turn over JSON-Lines
on stdin/stdout), reads each event the agent emits, and writes a `yes`
message back whenever the agent ends a turn with a confirmation prompt.
The loop terminates when the agent ends a turn without asking, the
turn cap is hit, or stdin/stdout closes.

Stream-json is one process for the whole session — no `--resume` round
trips, no context reload per turn.

Wire format notes (the `--input-format stream-json` protocol is
reverse-engineered — see github.com/anthropics/claude-code/issues/24594):
- `--verbose` is required when `--output-format stream-json` is set;
  without it the CLI errors out or emits nothing on recent versions.
- The agent signals "this turn is done, your move" via an `assistant`
  event whose `message.stop_reason == "end_turn"`. The `result` event
  fires ONCE per session (at stdin close), not per turn.
- User-message envelope on stdin matches the Agent SDK examples at
  code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode.
"""

from __future__ import annotations

import json
import queue
import re
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import IO

# Matches the literal protocol phrase the skills end on
# (see agents/skills/_x-x_shared/_plan_first.md: "Reply `yes` to proceed,
# or tell me what to change."). Case-insensitive, tolerant of backticks
# around `yes` and arbitrary whitespace.
CONFIRMATION_PATTERN = re.compile(r"reply\s+`?yes`?", re.IGNORECASE)

# A turn here = one user message + the full agent response (text + tool
# calls + tool results) until the agent emits its end-of-turn `result`
# event. A real planner+executor loop is bounded — /x-plan asks at most a
# handful of times, /x-x asks at most once per task per plan — but we cap
# to stop a misbehaving agent from looping forever.
DEFAULT_MAX_TURNS = 20

# Per-turn wall-clock cap. Claude on DeepSeek can spend 30–90s on a single
# turn that does real planning; 10 minutes is generous but still bounded.
DEFAULT_PER_TURN_TIMEOUT_S = 600.0


@dataclass
class SkillRun:
  """Captures everything observable about one driven Claude session."""

  workspace: Path
  initial_prompt: str
  transcript: list[dict] = field(default_factory=list)
  turns: int = 0
  yes_replies: int = 0
  completed: bool = False
  timed_out: bool = False
  exit_code: int | None = None
  stderr_tail: str = ""

  def save_transcript(self, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
      for event in self.transcript:
        f.write(json.dumps(event) + "\n")


def drive_skill(
  workspace: Path,
  initial_prompt: str,
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
  log_progress: bool = True,
) -> SkillRun:
  """Run one skill in `workspace` and auto-reply 'yes' until done.

  Returns a SkillRun summarizing the transcript, turn count, and how the
  session ended (completed normally / hit turn cap / timed out / exited).
  """
  run = SkillRun(workspace=workspace, initial_prompt=initial_prompt)

  cmd = [
    "claude",
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--verbose",
    "--dangerously-skip-permissions",
  ]
  proc = subprocess.Popen(
    cmd,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    cwd=str(workspace),
    text=True,
    bufsize=1,
  )

  out_q: queue.Queue[str | None] = queue.Queue()
  err_lines: list[str] = []
  threading.Thread(
    target=_pump_to_queue, args=(proc.stdout, out_q), daemon=True
  ).start()
  threading.Thread(
    target=_pump_to_list, args=(proc.stderr, err_lines), daemon=True
  ).start()

  _send_user_message(proc.stdin, initial_prompt, log_progress=log_progress)

  last_assistant_text = ""

  try:
    while True:
      try:
        line = out_q.get(timeout=per_turn_timeout)
      except queue.Empty:
        run.timed_out = True
        if log_progress:
          _log(f"[driver] timeout after {per_turn_timeout}s waiting for event")
        break

      if line is None:
        # stdout EOF — claude exited (probably after a `result` event).
        run.completed = True
        break
      if not line.strip():
        continue

      try:
        event = json.loads(line)
      except json.JSONDecodeError:
        run.transcript.append({"_raw": line})
        continue
      run.transcript.append(event)

      etype = event.get("type")
      if etype == "assistant":
        message = event.get("message", {}) or {}
        # Accumulate the final text block from this assistant message —
        # the confirmation prompt (if any) lives at the end of the text.
        for block in message.get("content", []) or []:
          if isinstance(block, dict) and block.get("type") == "text":
            last_assistant_text = block.get("text", "")

        # stop_reason "end_turn" means the agent is done with this turn
        # and is waiting for the next user message. Other stop_reasons
        # ("tool_use", "max_tokens", "stop_sequence") mean more events
        # are coming for the SAME turn — don't act on them.
        if message.get("stop_reason") == "end_turn":
          run.turns += 1
          if log_progress:
            _log(
              f"[driver] turn {run.turns} ended; "
              f"assistant said: {_brief(last_assistant_text)}"
            )
          if not _asks_for_confirmation(last_assistant_text):
            # No prompt — agent is done. Closing stdin will trigger the
            # session-end `result` event, then EOF on stdout.
            try:
              proc.stdin.close()
            except Exception:
              pass
            continue
          if run.turns >= max_turns:
            if log_progress:
              _log(f"[driver] hit max_turns={max_turns} cap; stopping")
            try:
              proc.stdin.close()
            except Exception:
              pass
            continue
          _send_user_message(proc.stdin, "yes", log_progress=log_progress)
          run.yes_replies += 1
          last_assistant_text = ""
      elif etype == "result":
        # Session-end summary. Stdout EOF should follow shortly.
        run.completed = True
        if log_progress:
          _log(f"[driver] result event; session ending after {run.turns} turn(s)")
  finally:
    try:
      proc.stdin.close()
    except Exception:
      pass
    try:
      proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
      proc.kill()
      proc.wait(timeout=5)
    run.exit_code = proc.returncode
    run.stderr_tail = "\n".join(err_lines[-40:])

  if transcript_path is not None:
    run.save_transcript(transcript_path)

  return run


def _send_user_message(stdin: IO[str], content: str, *, log_progress: bool) -> None:
  # Envelope shape matches the Agent SDK streaming-input example at
  # code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode.
  # parent_tool_use_id is null for top-level user messages (non-null
  # only when responding from within a sub-agent's tool call).
  msg = {
    "type": "user",
    "message": {"role": "user", "content": content},
    "parent_tool_use_id": None,
  }
  stdin.write(json.dumps(msg) + "\n")
  stdin.flush()
  if log_progress:
    _log(f"[driver] sent user message: {_brief(content)}")


def _pump_to_queue(stream: IO[str], q: queue.Queue[str | None]) -> None:
  try:
    for line in stream:
      q.put(line.rstrip("\n"))
  finally:
    q.put(None)


def _pump_to_list(stream: IO[str], sink: list[str]) -> None:
  for line in stream:
    sink.append(line.rstrip("\n"))


def _asks_for_confirmation(assistant_text: str) -> bool:
  return bool(CONFIRMATION_PATTERN.search(assistant_text or ""))


def _brief(text: str, limit: int = 140) -> str:
  collapsed = " ".join((text or "").split())
  return collapsed if len(collapsed) <= limit else collapsed[: limit - 1] + "…"


def _log(msg: str) -> None:
  print(msg, file=sys.stderr, flush=True)
