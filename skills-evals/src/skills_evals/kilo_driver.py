# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive a Kilo Code session non-interactively with auto-yes replies.

Same problem as `claude_driver`: the bundled x-x skills end every planner /
executor turn with "Reply yes to proceed". A single `kilo run` invocation is
one-shot — it returns once the agent stops talking, and a literal "yes" on
the next line never reaches the skill because the process is gone.

Workaround documented at https://kilo.ai/docs/code-with-ai/platforms/cli:
Kilo persists session history out-of-band and re-enters via `--continue` or
`--session <id>`. So the loop here is one `subprocess.Popen` *per turn*
rather than the long-lived stream-json process the Claude driver uses:

  turn 1: `kilo run --auto --format json "<initial_prompt>"`        (in cwd)
  turn N: `kilo run --auto --format json --session <id> "yes"`     (in cwd)

Wire-format notes — the Kilo `--format json` event stream is documented only
as "machine-readable event stream" with no public schema, so this parser is
defensive: every line is logged, every JSON object is searched for a
session-id-shaped field (`session_id`, `sessionId`, `session`, `id` on a
`session.*` event), and the auto-yes gate fires only on the LAST text we see
that matches the standard `reply yes` confirmation phrase. If the schema
shifts, `test_kilo_stream_smoke.py` is the canary — it pins the shape under
DeepSeek-on-openai-compatible routing and fails fast on drift.

Routing assumption: callers have written a project-scope `kilo.json` with an
`openai-compatible` provider stanza pointing at `api.deepseek.com/v1`. The
conftest does that during workspace setup. No env-var-only routing path
exists for custom OpenAI-compatible endpoints in Kilo today.

Logging policy: every state transition, every event, every external call
gets a line on stderr via `_logging.log`. Match `claude_driver` here — CI
logs are the only diagnostic surface, silence is a bug.
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

# Routing env vars echoed at startup so CI logs show exactly which provider
# kilo is reaching. KILOCODE_MODEL / KILO_API_KEY / KILO_PROVIDER are the
# documented overrides; KILO_ORG_ID is the recommended non-interactive
# organization selector. Anything containing a secret reports length +
# 4-char suffix, never the value.
ECHOED_ENV_KEYS = (
  "KILO_PROVIDER",
  "KILOCODE_MODEL",
  "KILO_ORG_ID",
)
SECRET_ENV_KEYS = ("KILO_API_KEY", "DEEPSEEK_API_KEY")


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
  """Run one skill in `workspace`, auto-replying 'yes' across kilo turns."""
  run = SkillRun(workspace=workspace, initial_prompt=initial_prompt)
  _log_startup(workspace, initial_prompt, max_turns, per_turn_timeout)

  message = initial_prompt
  loop_start = time.time()

  while True:
    if run.turns >= max_turns:
      log(
        "driver",
        f"hit max_turns={max_turns} (still being asked for confirmation); "
        f"stopping",
      )
      break

    turn_completed, turn_text = _run_one_turn(
      run,
      workspace=workspace,
      message=message,
      per_turn_timeout=per_turn_timeout,
    )
    run.turns += 1

    if not turn_completed:
      log("driver", f"turn {run.turns} did not complete cleanly — stopping")
      break

    if not _asks_for_confirmation(turn_text):
      log(
        "driver",
        f"turn {run.turns}: no confirmation prompt detected — session done",
      )
      run.completed = True
      break

    log("driver", f"turn {run.turns}: confirmation prompt detected; replying 'yes'")
    run.yes_replies += 1
    message = "yes"

  log(
    "driver",
    f"drive_skill returning turns={run.turns} yes_replies={run.yes_replies} "
    f"events={run.events_received} completed={run.completed} "
    f"timed_out={run.timed_out} session_id={run.session_id} "
    f"elapsed={time.time() - loop_start:.1f}s",
  )

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  return run


def _run_one_turn(
  run: SkillRun,
  *,
  workspace: Path,
  message: str,
  per_turn_timeout: float,
) -> tuple[bool, str]:
  """Spawn one `kilo run`, drain its output, return (completed, final_text).

  `completed` is False if the process timed out or exited non-zero. The
  caller decides whether to keep going (it usually shouldn't, but the
  transcript still gets the partial events for offline inspection).
  """
  cmd = ["kilo", "run", "--auto", "--format", "json"]
  if run.session_id is not None:
    cmd += ["--session", run.session_id]
  cmd.append(message)

  log("driver", f"spawn: {' '.join(_shell_quote(p) for p in cmd)}")
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

  last_text = ""
  turn_events = 0
  turn_start = time.time()
  timed_out = False

  while True:
    elapsed = time.time() - turn_start
    remaining = max(0.0, per_turn_timeout - elapsed)
    try:
      line = out_q.get(timeout=remaining)
    except queue.Empty:
      timed_out = True
      log(
        "driver",
        f"TIMEOUT after {per_turn_timeout}s on turn {run.turns + 1} "
        f"(events: {turn_events})",
      )
      break

    if line is None:
      log("driver", f"stdout EOF on turn {run.turns + 1}; events: {turn_events}")
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
    turn_events += 1

    _maybe_capture_session_id(run, event)
    candidate = _extract_assistant_text(event)
    if candidate:
      last_text = candidate

    _log_event(event, run.events_received)

  if timed_out:
    run.timed_out = True
    try:
      proc.terminate()
      proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
      log("driver", "kilo did not exit within 10s after terminate; killing")
      proc.kill()
      proc.wait(timeout=5)
  else:
    try:
      proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
      log("driver", "kilo did not exit within 15s of EOF; killing")
      proc.kill()
      proc.wait(timeout=5)

  run.exit_code = proc.returncode
  run.stderr_tail = "\n".join(err_lines[-40:])
  log(
    "driver",
    f"turn {run.turns + 1} done: exit={run.exit_code} events={turn_events} "
    f"elapsed={time.time() - turn_start:.1f}s "
    f"last_text={_brief(last_text, 120)}",
  )
  if turn_events == 0 and not timed_out:
    log(
      "driver",
      "WARNING: turn produced zero JSON events — wire format may be wrong "
      f"or kilo emitted on stderr only. stderr tail:\n{run.stderr_tail}",
    )

  completed = (not timed_out) and run.exit_code == 0
  return completed, last_text


def _log_startup(
  workspace: Path,
  initial_prompt: str,
  max_turns: int,
  per_turn_timeout: float,
) -> None:
  log("driver", f"drive_skill called: workspace={workspace}")
  log("driver", f"initial_prompt: {_brief(initial_prompt, 200)}")
  log("driver", f"max_turns={max_turns} per_turn_timeout={per_turn_timeout}s")

  kilo_path = shutil.which("kilo")
  log("driver", f"kilo on PATH: {kilo_path}")
  if kilo_path:
    try:
      out = subprocess.run(
        ["kilo", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"kilo --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"kilo --version failed: {e}")

  kilo_config = workspace / "kilo.json"
  if kilo_config.is_file():
    log("driver", f"workspace kilo.json present: {kilo_config}")
  else:
    log(
      "driver",
      f"workspace kilo.json MISSING at {kilo_config} — provider routing "
      f"may fall back to whatever kilo picks up from $HOME",
    )

  for key in ECHOED_ENV_KEYS:
    log("driver", f"env {key}={os.environ.get(key, '(unset)')}")
  for key in SECRET_ENV_KEYS:
    val = os.environ.get(key)
    if val:
      log("driver", f"env {key}=set (length={len(val)}, ...{val[-4:]})")
    else:
      log("driver", f"env {key}=MISSING")


def _maybe_capture_session_id(run: SkillRun, event: dict) -> None:
  """Best-effort: find a session ID anywhere it might live in the event.

  Schema is undocumented, so we look in every plausible spot. Once captured,
  we don't overwrite — Kilo's --session flag pins us to one history thread.
  """
  if run.session_id is not None:
    return
  for key in ("session_id", "sessionId", "session"):
    val = event.get(key)
    if isinstance(val, str) and val:
      run.session_id = val
      log("driver", f"captured session_id from event.{key}: {val}")
      return
    if isinstance(val, dict):
      inner = val.get("id")
      if isinstance(inner, str) and inner:
        run.session_id = inner
        log("driver", f"captured session_id from event.{key}.id: {inner}")
        return


def _extract_assistant_text(event: dict) -> str:
  """Pull the agent's final-text-ish content out of an event, best-effort.

  Kilo's event schema is undocumented; this checks every shape we can guess
  at. Returns "" if nothing text-like is found. The auto-yes detector keys
  off the LAST non-empty text seen across the turn, so false negatives just
  make us miss a `reply yes` (test will fail loudly); false positives are
  fine (we send a spurious "yes" which the agent ignores).
  """
  # Common shapes: {"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}
  msg = event.get("message")
  if isinstance(msg, dict):
    content = msg.get("content")
    if isinstance(content, str):
      return content
    if isinstance(content, list):
      pieces = []
      for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
          pieces.append(block.get("text", "") or "")
        elif isinstance(block, str):
          pieces.append(block)
      joined = "\n".join(p for p in pieces if p)
      if joined:
        return joined

  # Fallback shapes — agents sometimes emit flat text/content keys.
  for key in ("text", "content", "result"):
    val = event.get(key)
    if isinstance(val, str) and val.strip():
      return val
  return ""


def _log_event(event: dict, idx: int) -> None:
  etype = event.get("type", "?")
  subtype = event.get("subtype") or event.get("kind") or ""
  tag = f"{etype}/{subtype}" if subtype else etype
  log("driver", f"event #{idx} type={tag} body={_brief(json.dumps(event), 240)}")


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


def _shell_quote(s: str) -> str:
  if s and all(c.isalnum() or c in "-_./:=" for c in s):
    return s
  return "'" + s.replace("'", "'\\''") + "'"


def _brief(text: str, limit: int = 140) -> str:
  collapsed = " ".join((text or "").split())
  return collapsed if len(collapsed) <= limit else collapsed[: limit - 1] + "…"
