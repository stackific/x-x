# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive an OpenAI Codex CLI session non-interactively with auto-yes replies.

The x-x skills (`/x-plan`, `/x-x`) pause and ask the user to
`Reply yes to proceed`. A bare `codex exec "/x-plan ..."` invocation is
one-shot — it gets the question, exits without answering, and the skill
aborts before doing real work.

This module spawns `codex exec --json` (one process per turn — codex is
NOT a long-lived stream-json protocol like Claude Code; multi-turn is
done via `codex exec resume <session-id>`), reads every JSONL event the
agent emits, captures the session id from the first event, and on each
turn boundary checks the agent's final text for a `reply yes` prompt. If
yes, it re-invokes `codex exec resume <session-id> --json` with the
literal "yes" as the next prompt and continues.

Wire format notes (the `codex exec --json` protocol is documented at
developers.openai.com/codex/noninteractive; treat the surface as drifting
between minor codex-cli releases):

- Codex emits one JSON object per line on stdout. The lifecycle goes:
  `thread.started` (carries session id) → zero or more `item.*` events
  (agent text, tool calls, tool results, reasoning summaries) →
  `turn.completed` (carries token counts + final response).
- The end-of-turn signal is `turn.completed`. We do NOT key off process
  exit alone — codex exec ALSO exits at end of turn, but the structured
  event is the contract.
- Codex does not stay alive between turns. Each "yes" is a fresh
  `codex exec resume <session-id> --json "yes"`. The session-id binds
  the model context; the protocol gives us multi-turn without re-shipping
  the whole transcript on stdin.

DeepSeek routing: Codex's custom providers speak the OpenAI Responses
protocol, while DeepSeek's native API is Chat Completions. A direct
DeepSeek base_url does NOT work. The two stable bridges (per
`docs/internal/adding-agent-eval-backend.md`) are a local protocol
gateway (CCX) or OpenRouter BYOK. The shipped workflow uses OpenRouter:
`OPENROUTER_API_KEY` is required at process start; the `~/.codex/config.toml`
written by the workflow points `model_provider = "openrouter"` at the
OpenRouter base URL. The driver only echoes the env state — it does not
write config files.

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

# Codex env vars the driver echoes at startup so the CI log shows exactly
# which backend the agent is routed to. Secret-bearing vars are reported
# as set/MISSING with a 4-char suffix, never the raw value.
ECHOED_ENV_KEYS = (
  "CODEX_HOME",
  "CODEX_PROFILE",
)
SECRET_ENV_KEYS = (
  "OPENROUTER_API_KEY",
  "DEEPSEEK_API_KEY",
  "OPENAI_API_KEY",
)


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
  session_id: str | None = None

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

  prompt = initial_prompt
  for turn_idx in range(max_turns):
    final_text, turn_completed, exit_code, stderr_tail = _run_one_turn(
      workspace=workspace,
      prompt=prompt,
      session_id=run.session_id,
      per_turn_timeout=per_turn_timeout,
      run=run,
    )
    run.turns += 1
    run.exit_code = exit_code
    run.stderr_tail = stderr_tail

    if not turn_completed:
      # Either a timeout or codex exited without emitting `turn.completed`.
      # Both are terminal — bail without claiming completion.
      log(
        "driver",
        f"turn {run.turns}: no turn.completed event "
        f"(exit_code={exit_code}, timed_out={run.timed_out}) — stopping",
      )
      break

    log(
      "driver",
      f"turn {run.turns} ended (turn.completed). "
      f"final text: {_brief(final_text)}",
    )

    if not _asks_for_confirmation(final_text):
      log("driver", "no confirmation prompt — ending session")
      run.completed = True
      break

    if turn_idx + 1 >= max_turns:
      log(
        "driver",
        f"hit max_turns={max_turns} (still being asked for confirmation); "
        f"stopping",
      )
      break

    if run.session_id is None:
      log(
        "driver",
        "confirmation prompt detected but no session_id was captured; "
        "cannot resume — stopping",
      )
      break

    log(
      "driver",
      "confirmation prompt detected; sending 'yes' as resume to continue",
    )
    prompt = "yes"
    run.yes_replies += 1

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  log(
    "driver",
    f"drive_skill done: turns={run.turns} yes_replies={run.yes_replies} "
    f"events={run.events_received} session_id={run.session_id} "
    f"completed={run.completed} timed_out={run.timed_out} "
    f"exit_code={run.exit_code}",
  )

  return run


def _run_one_turn(
  *,
  workspace: Path,
  prompt: str,
  session_id: str | None,
  per_turn_timeout: float,
  run: SkillRun,
) -> tuple[str, bool, int | None, str]:
  """Run `codex exec [resume <id>] --json <prompt>` for one turn.

  Returns (final_text, turn_completed, exit_code, stderr_tail). The
  driver's `run` is mutated in place with the events seen, the session
  id (on first turn), and timed_out (on per-turn timeout).
  """
  cmd: list[str]
  if session_id is None:
    cmd = ["codex", "exec"]
  else:
    cmd = ["codex", "exec", "resume", session_id]
  cmd += [
    "--json",
    "--skip-git-repo-check",
    "--sandbox", "danger-full-access",
    prompt,
  ]
  log("driver", f"spawn: {' '.join(_shell_quote(a) for a in cmd)}")
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

  final_text = ""
  turn_completed = False
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
          f"(events seen so far this turn; elapsed: "
          f"{time.time() - loop_start:.1f}s)",
        )
        break

      if line is None:
        log("driver", "stdout EOF for this turn")
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

      if run.session_id is None:
        sid = _extract_session_id(event)
        if sid:
          run.session_id = sid
          log("driver", f"captured session_id={sid}")

      text = _extract_text_from_event(event)
      if text:
        final_text = text

      if _is_turn_completed(event):
        turn_completed = True
        # Codex closes the stream after turn.completed; keep draining
        # until stdout EOF so the transcript captures any trailing
        # housekeeping events.

  finally:
    try:
      proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
      log("driver", "codex did not exit within 15s after stream end; killing")
      proc.kill()
      proc.wait(timeout=5)

  exit_code = proc.returncode
  stderr_tail = "\n".join(err_lines[-40:])
  log(
    "driver",
    f"codex turn exited code={exit_code} "
    f"turn_completed={turn_completed} "
    f"elapsed={time.time() - loop_start:.1f}s",
  )
  return final_text, turn_completed, exit_code, stderr_tail


def _extract_session_id(event: dict) -> str | None:
  """Pull the session id from any event shape Codex might emit.

  Codex's documented `thread.started` event carries the id. Belt-and-
  suspenders: check a small set of plausible keys so a minor codex-cli
  rename doesn't silently break the resume path. If none match, return
  None and let the driver continue — the smoke test will surface it.
  """
  for key in ("thread_id", "session_id", "id"):
    val = event.get(key)
    if isinstance(val, str) and val:
      return val
  inner = event.get("thread") or event.get("session") or {}
  if isinstance(inner, dict):
    for key in ("id", "thread_id", "session_id"):
      val = inner.get(key)
      if isinstance(val, str) and val:
        return val
  return None


def _extract_text_from_event(event: dict) -> str:
  """Return the assistant-visible text in this event, or empty.

  Codex's `item.*` events wrap a typed payload; we care about the
  assistant message text (the thing that asks `reply yes`). The exact
  field name has drifted across codex-cli versions, so check a couple of
  plausible shapes. Anything we don't recognize returns empty — the
  driver tolerates that.
  """
  etype = event.get("type", "")
  if etype.startswith("item"):
    item = event.get("item") or event
    if isinstance(item, dict):
      payload = item.get("payload") or item
      if isinstance(payload, dict):
        for key in ("text", "content", "message"):
          val = payload.get(key)
          if isinstance(val, str) and val.strip():
            return val
          if isinstance(val, list):
            parts = []
            for block in val:
              if isinstance(block, dict):
                t = block.get("text")
                if isinstance(t, str):
                  parts.append(t)
              elif isinstance(block, str):
                parts.append(block)
            if parts:
              return "\n".join(parts)
  if etype == "turn.completed":
    response = event.get("response") or {}
    if isinstance(response, dict):
      for key in ("text", "output_text", "content"):
        val = response.get(key)
        if isinstance(val, str) and val.strip():
          return val
  for key in ("output_text", "text", "message"):
    val = event.get(key)
    if isinstance(val, str) and val.strip():
      return val
  return ""


def _is_turn_completed(event: dict) -> bool:
  etype = event.get("type", "")
  return etype == "turn.completed" or etype == "turn_completed"


def _log_startup(
  workspace: Path,
  initial_prompt: str,
  max_turns: int,
  per_turn_timeout: float,
) -> None:
  log("driver", f"drive_skill called: workspace={workspace}")
  log("driver", f"initial_prompt: {_brief(initial_prompt, 200)}")
  log("driver", f"max_turns={max_turns} per_turn_timeout={per_turn_timeout}s")

  codex_path = shutil.which("codex")
  log("driver", f"codex on PATH: {codex_path}")
  if codex_path:
    try:
      out = subprocess.run(
        ["codex", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"codex --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"codex --version failed: {e}")

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
  summary = _summarize_event(event)
  log("driver", f"event #{idx} type={etype} {summary}")


def _summarize_event(event: dict) -> str:
  etype = event.get("type", "")
  if etype == "thread.started":
    return f"thread_id={(event.get('thread_id') or event.get('id') or '?')[:16]}"
  if etype == "turn.completed":
    usage = event.get("usage") or {}
    return (
      f"input_tokens={usage.get('input_tokens', '?')} "
      f"output_tokens={usage.get('output_tokens', '?')} "
      f"final_text={_brief(_extract_text_from_event(event), 100)}"
    )
  if etype.startswith("item"):
    item = event.get("item") or {}
    item_type = item.get("type") or item.get("payload", {}).get("type") if isinstance(item, dict) else "?"
    text = _extract_text_from_event(event)
    if text:
      return f"item_type={item_type} text={_brief(text, 100)}"
    return f"item_type={item_type} {_brief(json.dumps(item), 100)}"
  # Anything else — dump it. CI logs are cheap.
  return _brief(json.dumps(event), 200)


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


def _shell_quote(arg: str) -> str:
  if not arg or any(c.isspace() or c in "\"'\\$`" for c in arg):
    return "'" + arg.replace("'", "'\\''") + "'"
  return arg
