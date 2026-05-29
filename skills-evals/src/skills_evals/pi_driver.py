# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive a Pi session non-interactively with auto-yes replies.

Mirrors the public surface intent of `opencode_driver.drive_command`, but
adapts to Pi's CLI conventions (pi.dev — `@earendil-works/pi-coding-agent`),
which differ from OpenCode in two ways that matter for the eval loop:

1. **Per-turn subprocess.** Pi's print mode (`pi -p ...` / `pi --mode json
   -p ...`) is single-shot: each invocation sends one user message, streams
   events to stdout as NDJSON, and exits when the agent finishes (`agent_end`
   event). There is no stay-alive multi-turn protocol — Anthropic's
   `stream-json` analog does not exist here. To drive multiple turns we
   re-invoke `pi -c -p ...` so the agent keeps its prior context (`-c` /
   `--continue` resumes the most recent session). The auto-yes loop is
   "spawn one process per `yes` reply".

2. **Slash commands resolve in print mode.** Pi parses `/skill:<name>` from
   the message body before dispatching to the model — `/skill:scope <task>`
   loads the SKILL.md whose frontmatter `name:` matches `scope` and appends
   the task as `User: <task>` per docs/skills.md in the pi-mono repo. Pi
   discovers skills from `.agents/skills/`, `.pi/skills/`, `~/.agents/skills/`,
   and `~/.pi/agent/skills/` (cwd up through ancestors). The bundled stax
   install lands SKILL.md files under `.agents/skills/scope/SKILL.md` (when
   `stax init --agents codex` runs, since codex's `.agents/skills` row in
   constants.go is the path pi also reads from). User-scope installs land
   them at `~/.agents/skills/`, which pi also discovers.

   This sidesteps the `/scope ...`-as-literal-text problem that OpenCode's
   inline-template workaround was built for (opencode's `run --command`
   evolved to a similar shape; pi's `/skill:<name>` is the equivalent).

Event stream: `pi --mode json` emits NDJSON. The relevant types
(packages/coding-agent/src/core/agent-session.ts in earendil-works/pi-mono):
  - `session`              one-line header
  - `agent_start`          run begins
  - `turn_start`           one conversational turn begins
  - `message_start`        assistant message draft created
  - `message_update`       streaming delta; `assistantMessageEvent.delta`
                           carries the text chunk
  - `message_end`          assembled assistant message; `.message.content`
                           is the canonical place to read final text
  - `turn_end`             turn done; `.message` + `.toolResults`
  - `agent_end`            run done; process exits next
  - `tool_execution_*`     tool lifecycle (read/write/edit/bash)
  - `reasoning_*`          thinking blocks — NOT included in auto-yes
                           detection (chain-of-thought may mention "yes")
  - `compaction_*` / `auto_retry_*` / `queue_update`  housekeeping

Routing: pi reads `DEEPSEEK_API_KEY` directly for the `deepseek` provider
(docs/providers.md in earendil-works/pi-mono). Model selection is passed
via `--model deepseek/<model-id>` from this driver at spawn time, matching
the opencode pattern.

Permissions: Pi has no permission popups by default ("No permission popups.
Run in a container, or build your own confirmation flow with extensions." —
the project philosophy, README.md). In CI (Ubuntu runner, single-shot
process per turn) tools execute without prompting — there is no
`--dangerously-skip-permissions` to pass because there is no gate.

Logging policy is identical to opencode_driver: every state transition,
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

# DeepSeek v4 pro via pi's `deepseek` provider. Pi accepts `provider/id`
# in --model; the bare `deepseek-v4-pro` form (without the `[1m]`
# variant suffix the Anthropic-shim path uses) is what Models.dev's
# deepseek registry exposes — the `[1m]` variant fails with
# `Model not found` in OpenCode's identical Models.dev path, and pi's
# upstream is the same registry.
DEFAULT_MODEL = "deepseek/deepseek-v4-pro"

# Appended to the user task in `drive_command` so pi lands it at the
# tail of the prompt (after the SKILL.md content pi resolved from
# `/skill:<name>`). Last-instruction-wins in attention.
#
# Same problem class as opencode: the planner SKILL.md has propose-and-
# wait gates and the executor SKILL.md has work-item-boundary review gates,
# neither of which surfaces as `Reply yes`. Without this directive the
# auto-yes regex misses and pi goes idle.
#
# Reused verbatim from opencode_driver — the gate semantics are skill-
# level, not agent-level. Keep both in sync until the SKILL.md evolves
# a canonical non-interactive marker.
CI_DIRECTIVE = (
  "\n\nOPERATING MODE: non-interactive CI evaluation. "
  "There is no human operator available to answer questions or grant "
  "approvals. Every gate the SKILL TEMPLATE above describes ('propose "
  "to user and wait for approval', 'STOP and ask', 'Reply yes to "
  "proceed', 'review per task', 'clarify only when underspecified', "
  "etc.) is auto-approved by default — treat the propose-or-clarify "
  "step as informational, immediately take the implied default or "
  "your best-judgment choice, and continue with the work. Never end "
  "a turn while the user's task below still has open work. Do not "
  "ask AskUserQuestion-style or text-prompt questions; make a "
  "reasonable choice and proceed. Follow the SKILL TEMPLATE "
  "instructions verbatim otherwise."
)

# Env vars echoed at startup for CI-log clarity. Anything carrying a
# secret reports as set/MISSING with a 4-char suffix, never the value.
ECHOED_ENV_KEYS = (
  "PI_OFFLINE",
  "PI_SKIP_VERSION_CHECK",
  "PI_TELEMETRY",
  "PI_CODING_AGENT_DIR",
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


def drive_command(
  workspace: Path,
  command: str,
  arguments: str = "",
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
  model: str = DEFAULT_MODEL,
) -> SkillRun:
  """Invoke `pi --mode json -p "/skill:<command> <arguments>"` then auto-yes.

  First turn spawns pi with `/skill:<command> <arguments>` as the message
  — pi's command parser resolves `/skill:<name>` against discovered skills
  (`.agents/skills/<name>/SKILL.md` with frontmatter `name: <name>`).
  Subsequent turns spawn `pi -c --mode json -p yes` with `yes` as the
  message until the agent stops asking for confirmation, the turn cap
  fires, or a subprocess exits non-zero.

  Arguments get `CI_DIRECTIVE` appended so pi places it at the end of the
  prompt (after the SKILL.md template). See the constant's docstring.
  """
  augmented_args = (arguments + CI_DIRECTIVE) if arguments else CI_DIRECTIVE.lstrip()
  # `/skill:<name>` parsing happens in pi's CLI command processor (not the
  # LLM). The argument string after the command becomes `User: <args>` per
  # docs/skills.md. Compose the literal message here so the transcript
  # records exactly what we sent.
  first_message = f"/skill:{command} {augmented_args}".rstrip()
  prompt_label = f"/skill:{command} {_brief(augmented_args, 100)}"
  return _drive_loop(
    workspace,
    prompt_label,
    first_cmd=_build_cmd(model),
    first_input=first_message,
    max_turns=max_turns,
    per_turn_timeout=per_turn_timeout,
    transcript_path=transcript_path,
    model=model,
  )


def drive_prompt(
  workspace: Path,
  prompt: str,
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
  model: str = DEFAULT_MODEL,
) -> SkillRun:
  """Send a raw prompt (no slash command) and auto-yes until done.

  Used by the smoke test — `pi --mode json -p "<prompt>"` with a trivial
  message. Same auto-yes loop semantics as `drive_command`; the only
  difference is the first turn's message body is not a `/skill:<name>`
  invocation.
  """
  return _drive_loop(
    workspace,
    _brief(prompt, 100),
    first_cmd=_build_cmd(model),
    first_input=prompt,
    max_turns=max_turns,
    per_turn_timeout=per_turn_timeout,
    transcript_path=transcript_path,
    model=model,
  )


def _drive_loop(
  workspace: Path,
  prompt_label: str,
  *,
  first_cmd: list[str],
  first_input: str,
  max_turns: int,
  per_turn_timeout: float,
  transcript_path: Path | None,
  model: str,
) -> SkillRun:
  """Shared per-turn loop used by both public entry points."""
  run = SkillRun(workspace=workspace, initial_prompt=prompt_label)
  _log_startup(workspace, prompt_label, max_turns, per_turn_timeout, model)

  if shutil.which("pi") is None:
    log("driver", "pi not on PATH — bailing")
    run.exit_code = 127
    run.stderr_tail = "pi binary not found on PATH"
    return run

  loop_start = time.time()
  next_cmd = first_cmd
  next_input = first_input

  try:
    for turn_idx in range(max_turns):
      log(
        "driver",
        f"turn {turn_idx + 1}/{max_turns} spawn: {' '.join(next_cmd)} -- "
        f"{_brief(next_input, 100)}",
      )
      log("driver", f"cwd: {workspace}")

      argv = [*next_cmd, "-p", next_input] if next_input else [*next_cmd, "-p"]
      # Pi's session save location and skill-discovery walk both key off
      # the process cwd. subprocess.Popen with `cwd=...` sets the child's
      # working directory; no separate PWD override is required for pi
      # (unlike opencode which reads `process.env.PWD ?? process.cwd()`).
      env = dict(os.environ)
      proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=str(workspace),
        env=env,
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

      try:
        proc.wait(timeout=15)
      except subprocess.TimeoutExpired:
        log("driver", "pi did not exit within 15s after stream end; killing")
        proc.kill()
        proc.wait(timeout=5)
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
          f"pi exited non-zero ({proc.returncode}); stopping. "
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
      next_cmd = _build_cmd(model, resume=True)
      next_input = "yes"
      run.yes_replies += 1
    else:
      log("driver", f"hit max_turns={max_turns} loop cap")
  finally:
    log(
      "driver",
      f"drive exiting: turns={run.turns} yes_replies={run.yes_replies} "
      f"events={run.events_received} completed={run.completed} "
      f"timed_out={run.timed_out} exit_code={run.exit_code} "
      f"elapsed={time.time() - loop_start:.1f}s",
    )

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  return run


def _build_cmd(
  model: str,
  *,
  resume: bool = False,
) -> list[str]:
  """Compose the pi argv head — flags only, message is appended by caller.

  `--mode json` emits NDJSON events on stdout; `--model deepseek/<id>`
  routes via Models.dev's deepseek provider entry which keys off
  `DEEPSEEK_API_KEY`. `-c` / `--continue` resumes the most recent saved
  session — used on every non-first turn so the auto-yes reply lands in
  the same conversation history as the original prompt.
  """
  cmd = [
    "pi",
    "--mode", "json",
    "--model", model,
  ]
  if resume:
    cmd.append("-c")
  return cmd


def _log_startup(
  workspace: Path,
  prompt_label: str,
  max_turns: int,
  per_turn_timeout: float,
  model: str,
) -> None:
  log("driver", f"drive called: workspace={workspace}")
  log("driver", f"initial: {prompt_label}")
  log(
    "driver",
    f"max_turns={max_turns} per_turn_timeout={per_turn_timeout}s "
    f"model={model}",
  )

  pi_path = shutil.which("pi")
  log("driver", f"pi on PATH: {pi_path}")
  if pi_path:
    try:
      out = subprocess.run(
        ["pi", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"pi --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"pi --version failed: {e}")

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

  if etype == "message_end":
    msg = event.get("message") or {}
    content = msg.get("content") or []
    text_parts = [
      item.get("text", "")
      for item in content
      if isinstance(item, dict) and item.get("type") == "text"
    ]
    joined = " ".join(p for p in text_parts if p)
    return f"text={_brief(joined, 160)}"

  if etype == "message_update":
    ame = event.get("assistantMessageEvent") or {}
    sub = ame.get("type", "?") if isinstance(ame, dict) else "?"
    delta = ame.get("delta") if isinstance(ame, dict) else None
    if isinstance(delta, str) and delta:
      return f"sub={sub} delta={_brief(delta, 100)}"
    return f"sub={sub}"

  if etype in ("tool_execution_start", "tool_execution_update", "tool_execution_end"):
    name = event.get("toolName", "?")
    args = event.get("args")
    is_err = event.get("isError")
    parts = [f"tool={name}"]
    if etype == "tool_execution_end":
      parts.append(f"isError={bool(is_err)}")
    if isinstance(args, dict):
      parts.append(f"args={_brief(json.dumps(args), 100)}")
    return " ".join(parts)

  if etype in ("turn_start", "turn_end"):
    if etype == "turn_end":
      results = event.get("toolResults") or []
      return f"tool_results={len(results)}"
    return ""

  if etype in ("agent_start", "agent_end"):
    if etype == "agent_end":
      msgs = event.get("messages") or []
      return f"messages={len(msgs)}"
    return ""

  if etype == "session":
    return f"id={str(event.get('id', '?'))[:12]} cwd={event.get('cwd', '?')}"

  if etype in ("compaction_start", "compaction_end", "auto_retry_start", "auto_retry_end"):
    return _brief(json.dumps(event), 160)

  return _brief(json.dumps(event), 200)


def _extract_text(event: dict) -> str:
  """Pull user-visible assistant text from one event, if any.

  Only `message_end` events with `message.role == "assistant"` count.
  Pi emits a matching `message_start` / `message_end` pair for every
  user message it sends too — those carry `role: "user"` and contain
  the SKILL.md content that `/skill:<name>` inlined. Without the role
  filter, the SKILL.md's literal "Reply `yes` to proceed" lines bleed
  into the auto-yes detector and force a spurious continuation turn
  before the model has even responded (observed in the first CI run:
  pi 402-errored on the API call, my driver still saw "Reply yes" in
  the echoed user message and queued a "yes" turn that also 402-errored).

  `message_update` carries per-token deltas and is noisy; the assembled
  `message.content` on `message_end` is the canonical place to read
  final text. Filtering out `reasoning` and `tool_execution_*` keeps
  the auto-yes detector from false-triggering on chain-of-thought or
  tool args.
  """
  if "_raw" in event:
    return ""
  if event.get("type") != "message_end":
    return ""
  msg = event.get("message")
  if not isinstance(msg, dict):
    return ""
  if msg.get("role") != "assistant":
    return ""
  content = msg.get("content")
  if not isinstance(content, list):
    return ""
  parts: list[str] = []
  for item in content:
    if not isinstance(item, dict):
      continue
    if item.get("type") != "text":
      continue
    txt = item.get("text")
    if isinstance(txt, str) and txt:
      parts.append(txt)
  return "\n".join(parts)


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
