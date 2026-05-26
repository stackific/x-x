# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive an OpenCode session non-interactively with auto-yes replies.

Mirrors the public surface of `claude_driver.drive_skill`, but adapts to
OpenCode's CLI conventions which differ from Claude Code's in three ways
that matter for the eval loop:

1. **Per-turn subprocess.** `opencode run` is single-shot: each invocation
   sends one user message, streams the agent's response, and exits. There
   is no stdin-based multi-turn protocol (the equivalent of Claude's
   stream-json). To drive multiple turns we re-invoke `opencode run` with
   `--continue` (resume the last session) so the agent keeps its prior
   context. The auto-yes loop becomes "spawn one process per `yes` reply".

2. **`--format json` event stream.** OpenCode emits JSON Lines on stdout
   when `--format json` is set. Each line is one event. The wire format
   isn't as well-documented as Claude's, so this driver logs every
   non-trivial line type and keeps a permissive parser — anything we
   can't classify lands in the transcript verbatim.

3. **Slash commands are NOT resolved by `opencode run`.** Known open
   issue: anomalyco/opencode#7345, with feature requests
   anomalyco/opencode#2330 and #5073 tracking a `--command` flag /
   `opencode run "/cmd"` resolution path. Until those land, the test
   harness must INLINE the SKILL.md content into the prompt rather than
   send `"/x-plan <task>"` verbatim — the literal `/x-plan` would be
   passed to the LLM, which would hallucinate an error. The
   `compose_skill_prompt` helper below builds an inlined prompt from a
   SKILL.md path + task description.

Routing: OpenCode reads provider credentials from `DEEPSEEK_API_KEY` for
the `deepseek` provider (the same env var the judge uses). The
`--model deepseek/<model-id>` flag selects the model.

Logging policy is identical to claude_driver: every state transition,
every event, every external call gets a line on stderr via
`_logging.log`. CI logs are the only diagnostic surface.
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

DEFAULT_MODEL = "deepseek/deepseek-v4-pro[1m]"

# Env vars echoed at startup for CI-log clarity. Anything carrying a
# secret reports as set/MISSING with a 4-char suffix, never the value.
ECHOED_ENV_KEYS = (
  "OPENCODE_MODEL",
  "OPENCODE_PROVIDER",
)
SECRET_ENV_KEYS = ("DEEPSEEK_API_KEY",)


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
  model: str = DEFAULT_MODEL,
) -> SkillRun:
  """Run one skill in `workspace` and auto-reply 'yes' until done.

  Each "turn" is a fresh `opencode run` subprocess. The first turn
  carries the initial prompt; subsequent turns use `--continue` to
  resume the same session and pass `yes` as the prompt. The loop ends
  when the agent's final response no longer asks for confirmation, when
  `max_turns` is hit, or when a subprocess returns non-zero.
  """
  run = SkillRun(workspace=workspace, initial_prompt=initial_prompt)
  _log_startup(workspace, initial_prompt, max_turns, per_turn_timeout, model)

  if shutil.which("opencode") is None:
    log("driver", "opencode not on PATH — bailing")
    run.exit_code = 127
    run.stderr_tail = "opencode binary not found on PATH"
    return run

  loop_start = time.time()
  next_prompt = initial_prompt
  use_continue = False

  try:
    for turn_idx in range(max_turns):
      cmd = _build_cmd(model, use_continue)
      log("driver", f"turn {turn_idx + 1}/{max_turns} spawn: {' '.join(cmd)}")
      log("driver", f"cwd: {workspace}")
      log("driver", f"prompt: {_brief(next_prompt, 200)}")

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

      # Hand the prompt over on stdin then close it — opencode does not
      # accept a multi-message stdin stream, so the close is the signal
      # that we are done sending input for this turn.
      try:
        if proc.stdin is not None:
          proc.stdin.write(next_prompt)
          proc.stdin.close()
      except BrokenPipeError as e:
        log("driver", f"stdin write failed (pipe closed early): {e}")

      out_q: queue.Queue[str | None] = queue.Queue()
      err_lines: list[str] = []
      threading.Thread(
        target=_pump_to_queue, args=(proc.stdout, out_q), daemon=True
      ).start()
      threading.Thread(
        target=_pump_stderr_live, args=(proc.stderr, err_lines), daemon=True
      ).start()

      turn_text_chunks: list[str] = []
      turn_start = time.time()

      while True:
        try:
          line = out_q.get(timeout=per_turn_timeout)
        except queue.Empty:
          run.timed_out = True
          log(
            "driver",
            f"TIMEOUT after {per_turn_timeout}s waiting for next event "
            f"on turn {turn_idx + 1} (events seen so far: "
            f"{run.events_received}, elapsed since spawn: "
            f"{time.time() - turn_start:.1f}s)",
          )
          proc.kill()
          break

        if line is None:
          log(
            "driver",
            f"stdout EOF on turn {turn_idx + 1}; events this turn: "
            f"{len(turn_text_chunks)}",
          )
          break
        if not line.strip():
          continue

        event = _parse_event(line)
        run.transcript.append(event)
        run.events_received += 1
        _log_event(event, run.events_received)

        text = _extract_text(event)
        if text:
          turn_text_chunks.append(text)

      proc.wait(timeout=15)
      run.exit_code = proc.returncode
      run.stderr_tail = "\n".join(err_lines[-40:])
      run.turns += 1

      log(
        "driver",
        f"turn {turn_idx + 1} ended: exit={proc.returncode} "
        f"text_chunks={len(turn_text_chunks)} "
        f"elapsed={time.time() - turn_start:.1f}s",
      )

      if proc.returncode != 0:
        log(
          "driver",
          f"opencode exited non-zero ({proc.returncode}); stopping. "
          f"stderr tail:\n{run.stderr_tail}",
        )
        break

      if run.timed_out:
        break

      final_text = "\n".join(turn_text_chunks)
      if not _asks_for_confirmation(final_text):
        log("driver", "no confirmation prompt in final text — session done")
        run.completed = True
        break

      log("driver", "confirmation prompt detected; queueing 'yes' for next turn")
      next_prompt = "yes"
      use_continue = True
      run.yes_replies += 1
    else:
      log("driver", f"hit max_turns={max_turns} loop cap")
  finally:
    log(
      "driver",
      f"drive_skill exiting: turns={run.turns} yes_replies={run.yes_replies} "
      f"events={run.events_received} completed={run.completed} "
      f"timed_out={run.timed_out} exit_code={run.exit_code} "
      f"elapsed={time.time() - loop_start:.1f}s",
    )

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  return run


def resolve_skill_template(workspace: Path, skill_name: str) -> Path:
  """Locate a SKILL.md inside `.opencode/commands/<skill_name>/`.

  Checks project scope first (under the eval workspace), then user
  scope (under `$HOME`), matching the project-then-user resolution rule
  documented in the bundled SKILL.md files. Raises FileNotFoundError
  with a clear message naming both candidates if neither exists — keeps
  failure modes in CI logs unambiguous.

  `skill_name` is the directory name under `.opencode/commands/`, e.g.
  `x-plan` or `x-x`. The `.opencode/commands/<skill_name>/SKILL.md`
  layout matches what `x-x init --agents opencode` writes; it mirrors
  the shared SKILL.md open standard rather than OpenCode's flat-file
  command convention. See constants.go:agentTargets[opencode] for why.
  """
  candidates = [
    workspace / ".opencode" / "commands" / skill_name / "SKILL.md",
    Path.home() / ".opencode" / "commands" / skill_name / "SKILL.md",
  ]
  for candidate in candidates:
    if candidate.is_file():
      return candidate
  raise FileNotFoundError(
    f"SKILL.md for '{skill_name}' not found at any of: "
    + ", ".join(str(c) for c in candidates)
  )


def compose_skill_prompt(skill_md_path: Path, task: str) -> str:
  """Build a prompt that inlines a SKILL.md template + task.

  Workaround for anomalyco/opencode#7345 — `opencode run` does not
  resolve slash commands today, so `/x-plan <task>` is passed verbatim
  to the LLM and hallucinated as a missing command. Instead, read the
  SKILL.md content off disk and concatenate it with the task. This
  exercises the agent's behavior on the skill prompt without depending
  on OpenCode's resolver.

  Tests call this with a SKILL.md path under
  `<workspace>/.opencode/commands/<skill>/SKILL.md` (the location
  `x-x init --agents opencode` writes to).
  """
  if not skill_md_path.is_file():
    raise FileNotFoundError(f"skill template not found: {skill_md_path}")
  template = skill_md_path.read_text(encoding="utf-8")
  return (
    f"You are about to follow the skill instructions below verbatim, "
    f"as if the user invoked the matching slash command in your TUI. "
    f"Treat everything in the SKILL TEMPLATE block as the operative "
    f"prompt; the user's task follows it.\n\n"
    f"--- SKILL TEMPLATE ({skill_md_path.name}) ---\n"
    f"{template}\n"
    f"--- END SKILL TEMPLATE ---\n\n"
    f"User task: {task}"
  )


def _build_cmd(model: str, use_continue: bool) -> list[str]:
  cmd = [
    "opencode", "run",
    "--format", "json",
    "--model", model,
    "--dangerously-skip-permissions",
  ]
  if use_continue:
    cmd.append("--continue")
  return cmd


def _log_startup(
  workspace: Path,
  initial_prompt: str,
  max_turns: int,
  per_turn_timeout: float,
  model: str,
) -> None:
  log("driver", f"drive_skill called: workspace={workspace}")
  log("driver", f"initial_prompt: {_brief(initial_prompt, 200)}")
  log(
    "driver",
    f"max_turns={max_turns} per_turn_timeout={per_turn_timeout}s "
    f"model={model}",
  )

  opencode_path = shutil.which("opencode")
  log("driver", f"opencode on PATH: {opencode_path}")
  if opencode_path:
    try:
      out = subprocess.run(
        ["opencode", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"opencode --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"opencode --version failed: {e}")

  for key in ECHOED_ENV_KEYS:
    log("driver", f"env {key}={os.environ.get(key, '(unset)')}")
  for key in SECRET_ENV_KEYS:
    val = os.environ.get(key)
    if val:
      log("driver", f"env {key}=set (length={len(val)}, ...{val[-4:]})")
    else:
      log("driver", f"env {key}=MISSING")


def _parse_event(line: str) -> dict:
  """Parse one JSON-Lines event; fall back to a raw envelope on errors.

  OpenCode's `--format json` wire format isn't fully documented; the
  driver is forgiving so a single malformed line doesn't kill the run.
  Unparseable lines land in the transcript verbatim under a `_raw` key
  so post-hoc inspection can still see what came across the wire.
  """
  try:
    return json.loads(line)
  except json.JSONDecodeError:
    return {"_raw": line}


def _log_event(event: dict, idx: int) -> None:
  etype = event.get("type") or ("raw" if "_raw" in event else "?")
  summary = _summarize_event(event)
  log("driver", f"event #{idx} type={etype} {summary}")


def _summarize_event(event: dict) -> str:
  if "_raw" in event:
    return _brief(event["_raw"], 200)

  etype = event.get("type")
  if etype in ("text", "message", "assistant"):
    text = (
      event.get("text")
      or event.get("content")
      or event.get("message", {}).get("content", "")
    )
    if isinstance(text, list):
      text = " ".join(str(t) for t in text)
    return f"text={_brief(str(text), 120)}"

  if etype in ("tool_use", "tool", "tool_call"):
    return (
      f"name={event.get('name') or event.get('tool', '?')} "
      f"input={_brief(json.dumps(event.get('input', {})), 100)}"
    )

  if etype in ("error", "abort"):
    return f"error={_brief(str(event.get('message') or event.get('error', '')), 200)}"

  return _brief(json.dumps(event), 200)


def _extract_text(event: dict) -> str:
  """Pull the assistant-visible text from one event, if any.

  We're forgiving here — different event shapes carry text in different
  fields. Anything we can't recognize returns empty string, which
  simply means the auto-yes detector doesn't see it for this event.
  """
  if "_raw" in event:
    return ""

  etype = event.get("type")
  if etype in ("text", "message"):
    val = event.get("text") or event.get("content")
    if isinstance(val, str):
      return val
    if isinstance(val, list):
      return " ".join(str(v) for v in val if v is not None)
    return ""

  if etype == "assistant":
    msg = event.get("message", {}) or {}
    content = msg.get("content")
    if isinstance(content, str):
      return content
    if isinstance(content, list):
      out: list[str] = []
      for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
          out.append(str(block.get("text", "")))
      return "\n".join(out)
    return ""

  # Some opencode event shapes put text at top level (e.g. `output`,
  # `result`). Try those last so the structured cases above win.
  for key in ("output", "result", "delta"):
    val = event.get(key)
    if isinstance(val, str) and val:
      return val
  return ""


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
