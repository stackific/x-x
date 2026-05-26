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
turn cap is hit, the session-end `result` event arrives, or stdout closes.

Stream-json is one process for the whole session — no `--resume` round
trips, no context reload per turn.

Wire format notes (the `--input-format stream-json` protocol is
reverse-engineered — see github.com/anthropics/claude-code/issues/24594):
- `--verbose` is required when `--output-format stream-json` is set;
  without it the CLI errors out or emits nothing on recent versions.
- The agent signals "this turn is done, your move" via a `result` event,
  one per user-message→agent-response cycle. The community docs that
  claim `result` fires only once at session end are wrong (or wrong for
  the DeepSeek-on-Anthropic-wire compat shim we route through here).
  Verified empirically across 36+25 event runs: every `assistant` event
  has `stop_reason: None`, every user→agent cycle ends with a `result`.
- User-message envelope on stdin matches the Agent SDK examples at
  code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode.

Logging policy: every state transition, every event, every external call
gets a line on stderr via `_logging.log`. CI logs are the only diagnostic
surface — silence is a bug.
"""

from __future__ import annotations

import json
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

DEFAULT_MAX_TURNS = 20
DEFAULT_PER_TURN_TIMEOUT_S = 600.0

# Claude Code env vars the driver echoes at startup so the CI log shows
# exactly which backend the agent is routed to. Anything containing a
# secret is reported as set/MISSING with a 4-char suffix, never the value.
ECHOED_ENV_KEYS = (
  "ANTHROPIC_BASE_URL",
  "ANTHROPIC_MODEL",
  "ANTHROPIC_DEFAULT_OPUS_MODEL",
  "ANTHROPIC_DEFAULT_SONNET_MODEL",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  "CLAUDE_CODE_SUBAGENT_MODEL",
  "CLAUDE_CODE_EFFORT_LEVEL",
)
SECRET_ENV_KEYS = ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "DEEPSEEK_API_KEY")


@dataclass
class SkillRun:
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
      for event in self.transcript:
        f.write(json.dumps(event) + "\n")


def drive_skill(
  workspace: Path,
  initial_prompt: str,
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
) -> SkillRun:
  """Run one skill in `workspace` and auto-reply 'yes' until done."""
  run = SkillRun(workspace=workspace, initial_prompt=initial_prompt)

  _log_startup(workspace, initial_prompt, max_turns, per_turn_timeout)

  cmd = [
    "claude",
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--verbose",
    "--dangerously-skip-permissions",
  ]
  log("driver", f"spawn: {' '.join(cmd)}")
  log("driver", f"cwd: {workspace}")

  proc = subprocess.Popen(
    cmd,
    stdin=subprocess.PIPE,
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

  _send_user_message(proc.stdin, initial_prompt)

  last_assistant_text = ""
  loop_start = time.time()

  try:
    while True:
      try:
        line = out_q.get(timeout=per_turn_timeout)
      except queue.Empty:
        run.timed_out = True
        log(
          "driver",
          f"TIMEOUT after {per_turn_timeout}s waiting for next event "
          f"(events seen: {run.events_received}, turns: {run.turns}, "
          f"elapsed since spawn: {time.time() - loop_start:.1f}s)",
        )
        break

      if line is None:
        log("driver", f"stdout EOF (claude exited); events seen: {run.events_received}")
        run.completed = True
        break
      if not line.strip():
        continue

      try:
        event = json.loads(line)
      except json.JSONDecodeError as e:
        log("driver", f"unparseable line ({e}): {line[:200]}")
        run.transcript.append({"_raw": line})
        continue
      run.transcript.append(event)
      run.events_received += 1

      _log_event(event, run.events_received)

      etype = event.get("type")
      if etype == "assistant":
        message = event.get("message", {}) or {}
        # Accumulate text from this assistant message. We log every
        # assistant event's stop_reason for diagnostic purposes (it is
        # always None when routed through DeepSeek's compat shim — see
        # wire format notes at top of file) but do NOT key off it.
        # The turn-end signal in this wire is the `result` event below.
        for block in message.get("content", []) or []:
          if isinstance(block, dict) and block.get("type") == "text":
            last_assistant_text = block.get("text", "")

      elif etype == "result":
        # A `result` event ends one user→agent cycle. Decide whether to
        # send "yes" to a confirmation prompt or end the session here.
        # `result_text` is the final assistant message text; fall back
        # to accumulated last_assistant_text if empty (defense in depth).
        result_text = event.get("result", "") or ""
        check_text = result_text or last_assistant_text
        run.turns += 1
        log(
          "driver",
          f"turn {run.turns} ended (result event). "
          f"final text: {_brief(check_text)}",
        )

        if not _asks_for_confirmation(check_text):
          log(
            "driver",
            "no confirmation prompt — closing stdin to end session",
          )
          run.completed = True
          _close_stdin(proc)
          # Don't break — let the loop drain to EOF so we know the
          # process actually exited (line is None branch sets completed
          # and breaks).
          continue

        if run.turns >= max_turns:
          log(
            "driver",
            f"hit max_turns={max_turns} (still being asked for "
            f"confirmation); closing stdin and stopping",
          )
          _close_stdin(proc)
          continue

        log(
          "driver",
          "confirmation prompt detected in result; sending 'yes' to continue",
        )
        if not _send_user_message_safely(proc.stdin, "yes"):
          # Pipe is closed — claude has already exited after the result
          # event. We can't drive any more turns.
          log(
            "driver",
            "stdin pipe closed before 'yes' could be sent; agent exited "
            "after result. multi-turn auto-yes not supported on this "
            "Claude Code version / wire combination.",
          )
          break
        run.yes_replies += 1
        last_assistant_text = ""

  finally:
    _close_stdin(proc)
    try:
      proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
      log("driver", "claude did not exit within 15s after stdin close; killing")
      proc.kill()
      proc.wait(timeout=5)
    run.exit_code = proc.returncode
    run.stderr_tail = "\n".join(err_lines[-40:])
    log(
      "driver",
      f"claude exited code={run.exit_code} "
      f"turns={run.turns} yes_replies={run.yes_replies} "
      f"events={run.events_received} "
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
  max_turns: int,
  per_turn_timeout: float,
) -> None:
  log("driver", f"drive_skill called: workspace={workspace}")
  log("driver", f"initial_prompt: {_brief(initial_prompt, 200)}")
  log("driver", f"max_turns={max_turns} per_turn_timeout={per_turn_timeout}s")

  claude_path = shutil.which("claude")
  log("driver", f"claude on PATH: {claude_path}")
  if claude_path:
    try:
      out = subprocess.run(
        ["claude", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"claude --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"claude --version failed: {e}")

  for key in ECHOED_ENV_KEYS:
    log("driver", f"env {key}={os.environ.get(key, '(unset)')}")
  for key in SECRET_ENV_KEYS:
    val = os.environ.get(key)
    if val:
      log("driver", f"env {key}=set (length={len(val)}, ...{val[-4:]})")
    else:
      log("driver", f"env {key}=MISSING")


def _log_event(event: dict, idx: int) -> None:
  etype = event.get("type", "?")
  subtype = event.get("subtype", "")
  tag = f"{etype}/{subtype}" if subtype else etype
  summary = _summarize_event(event)
  log("driver", f"event #{idx} type={tag} {summary}")


def _summarize_event(event: dict) -> str:
  etype = event.get("type")
  subtype = event.get("subtype", "")

  if etype == "assistant":
    msg = event.get("message", {}) or {}
    blocks = msg.get("content", []) or []
    block_summaries = []
    for b in blocks:
      if not isinstance(b, dict):
        continue
      bt = b.get("type", "?")
      if bt == "text":
        block_summaries.append(f"text({_brief(b.get('text', ''), 60)})")
      elif bt == "tool_use":
        block_summaries.append(f"tool_use({b.get('name', '?')})")
      elif bt == "tool_result":
        block_summaries.append(f"tool_result(id={b.get('tool_use_id', '?')[:8]})")
      elif bt == "thinking":
        block_summaries.append(f"thinking({_brief(b.get('thinking', ''), 40)})")
      else:
        block_summaries.append(bt)
    usage = msg.get("usage", {}) or {}
    return (
      f"id={(msg.get('id') or '?')[:12]} "
      f"stop_reason={msg.get('stop_reason')!r} "
      f"model={msg.get('model', '?')} "
      f"blocks=[{', '.join(block_summaries)}] "
      f"usage_in={usage.get('input_tokens', '?')} "
      f"usage_out={usage.get('output_tokens', '?')}"
    )

  if etype == "user":
    msg = event.get("message", {}) or {}
    content = msg.get("content")
    if isinstance(content, str):
      return f"text={_brief(content, 100)}"
    if isinstance(content, list):
      return f"blocks={len(content)}"
    return "(empty)"

  if etype == "system":
    if subtype == "init":
      return (
        f"model={event.get('model')} "
        f"session={(event.get('session_id') or '?')[:12]} "
        f"tools={len(event.get('tools', []) or [])} "
        f"mcp_servers={len(event.get('mcp_servers', []) or [])} "
        f"permissionMode={event.get('permissionMode')} "
        f"apiKeySource={event.get('apiKeySource')}"
      )
    if subtype == "api_retry":
      return (
        f"attempt={event.get('attempt')} "
        f"max={event.get('max_retries')} "
        f"delay_ms={event.get('retry_delay_ms')} "
        f"error={event.get('error')} "
        f"status={event.get('error_status')}"
      )
    # Unknown system subtype — dump it. CI logs are cheap.
    return json.dumps({k: v for k, v in event.items() if k not in ("type",)})[:400]

  if etype == "result":
    return (
      f"subtype={subtype} "
      f"is_error={event.get('is_error')} "
      f"num_turns={event.get('num_turns')} "
      f"duration_ms={event.get('duration_ms')} "
      f"duration_api_ms={event.get('duration_api_ms')} "
      f"cost_usd={event.get('total_cost_usd')} "
      f"result_text={_brief(str(event.get('result', '')), 100)}"
    )

  if etype == "stream_event":
    inner = event.get("event", {}) or {}
    return f"inner_type={inner.get('type')} {_brief(json.dumps(inner), 100)}"

  # Anything else — dump it raw so we can spot unexpected types.
  return _brief(json.dumps(event), 200)


def _send_user_message(stdin: IO[str], content: str) -> None:
  msg = {
    "type": "user",
    "message": {"role": "user", "content": content},
    "parent_tool_use_id": None,
  }
  payload = json.dumps(msg)
  stdin.write(payload + "\n")
  stdin.flush()
  log("driver", f"sent user message ({len(payload)} bytes): {_brief(content, 100)}")


def _send_user_message_safely(stdin: IO[str], content: str) -> bool:
  """Send a user message, returning False if the pipe is already closed.

  Used for replies sent after a `result` event, where claude may have
  exited even though we want to drive another turn. A closed pipe is a
  real failure mode (not a bug), not an exception to swallow silently.
  """
  if stdin is None or stdin.closed:
    return False
  try:
    _send_user_message(stdin, content)
    return True
  except (BrokenPipeError, ValueError) as e:
    # ValueError covers "I/O operation on closed file" from text-mode IO.
    log("driver", f"send failed: {type(e).__name__}: {e}")
    return False


def _close_stdin(proc: subprocess.Popen) -> None:
  try:
    if proc.stdin and not proc.stdin.closed:
      proc.stdin.close()
      log("driver", "closed stdin")
  except Exception as e:
    log("driver", f"close stdin error (ignored): {e}")


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


def _asks_for_confirmation(assistant_text: str) -> bool:
  return bool(CONFIRMATION_PATTERN.search(assistant_text or ""))


def _brief(text: str, limit: int = 140) -> str:
  collapsed = " ".join((text or "").split())
  return collapsed if len(collapsed) <= limit else collapsed[: limit - 1] + "…"
