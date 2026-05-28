# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive an OpenCode session non-interactively with auto-yes replies.

Mirrors the public surface intent of `claude_driver.drive_skill`, but adapts to
OpenCode's CLI conventions which differ from Claude Code's in three ways
that matter for the eval loop:

1. **Per-turn subprocess.** `opencode run` is single-shot: each invocation
   sends one user message, streams events to stdout, and exits when the
   session goes idle. There is no stdin-based multi-turn stream-json
   protocol (the Claude analog). To drive multiple turns we re-invoke
   `opencode run --continue` so the agent keeps its prior context. The
   auto-yes loop becomes "spawn one process per `yes` reply".

2. **Slash commands resolve via `--command`.** `opencode run --command <name>`
   resolves <name> against `.opencode/{command,commands}/**/*.md` and the
   skill registry (`.claude/skills/`, `.agents/skills/`, etc.). The lookup
   keys off the file's frontmatter `name:` value, not the on-disk path —
   so `x-x init --agents opencode` writing `.opencode/commands/x-plan/SKILL.md`
   with `name: x-plan` registers a command callable as
   `opencode run --command x-plan`. Verified empirically against opencode 1.x.
   This sidesteps the `/x-plan ...`-as-literal-text problem the earlier
   inline-template workaround was built for.

   When the command template has no `$ARGUMENTS` / `$N` placeholders,
   opencode appends the positional message to the template body
   (session/prompt.ts in sst/opencode). The bundled x-x SKILL.md files
   don't carry placeholders, so the user task lands at the end of the
   prompt verbatim.

3. **`--format json` event stream.** Each line of stdout is one JSON
   event. Types emitted today: `text`, `tool_use`, `step_start`,
   `step_finish`, `reasoning`, `error`. Each carries a `part` envelope
   with the actual payload. The driver logs every event for CI debug
   surface and only extracts user-visible text from `text` events for
   the auto-yes detector (`reasoning` is internal chain-of-thought; if
   we keyed off it the detector would false-trigger on "yes" mentioned
   inside thinking).

Routing: OpenCode reads provider credentials from `DEEPSEEK_API_KEY` for
the `deepseek` provider (the same env var the judge uses). The
`--model deepseek/<model-id>` flag selects the model.

Non-interactive permission rules: `opencode run` (without `--interactive`)
creates the session with `permission: question, action: deny` baked in
(see sst/opencode packages/opencode/src/cli/cmd/run.ts). The agent
therefore cannot raise a TUI confirmation prompt — instead it follows
the SKILL.md's `Reply yes to proceed` checkpoints by emitting that text
and going idle. The driver keys off that text to send `yes` on the next
turn.

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

DEFAULT_MODEL = "deepseek/deepseek-v4-pro"

# Appended to the user task in `drive_command` so opencode lands it at
# the tail of the prompt (after the SKILL.md template body opencode
# resolved from `--command <name>`). Last-instruction-wins in attention.
#
# Targets the two gates that stranded sessions in the first green-on-CI
# attempts:
#
#   1. Empty systems registry. `x-plan` SKILL.md Appendix C step 4 says
#      "STOP. Propose a new system to the user. On approval, add to
#      _data_systems.yaml. Then continue." The propose-and-wait wording
#      doesn't surface as `Reply yes` so the auto-yes regex misses it
#      and opencode goes idle.
#
#   2. Destructive overwrites in the executor. When `x-x` runs a plan
#      whose system already has an existing artifact (e.g. a reminders
#      plan that supersedes a todo plan, with the todo's index.html
#      already on disk), the model emits a checkpoint message like
#      "FYI: I'll review the whole plan with you at once" and goes
#      idle waiting for a `review per task` reply.
#
# Claude doesn't need this — the slash-command framing in Claude Code
# resolves the same SKILL.md differently and the model is less hesitant.
# This is opencode-specific and lives next to the driver, not in the
# SKILL.md (which has to stay agent-agnostic).
# NOTE: must not begin with `-` / `--`. The string is passed as an argv
# element to `opencode run`, and yargs treats any element starting with
# `--` as a flag (or as the `--` separator). When `arguments=""` we send
# the directive alone — a leading `---` parsed as a flag, opencode
# printed its help banner, and the run exited 1.
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
# Note: the trailing "[1m]" variant suffix that Claude Code uses
# (`deepseek-v4-pro[1m]` — the 1M-context build) is an Anthropic-shim
# convention. OpenCode reads provider/model IDs from Models.dev's
# deepseek registry, which exposes the plain IDs only
# (`deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-chat`). Adding the
# `[1m]` suffix to the --model flag fails fast with:
#   Model not found: deepseek/deepseek-v4-pro[1m]. Did you mean:
#   deepseek-v4-pro, deepseek-v4-flash, deepseek-chat?

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
  """Invoke `opencode run --command <command> <arguments>` then auto-yes.

  First turn spawns `opencode run --command <command>` with the task as
  the positional message. Subsequent turns spawn `opencode run --continue`
  with `yes` as the message until the agent stops asking for confirmation,
  the turn cap fires, or a subprocess exits non-zero.

  Arguments get `CI_DIRECTIVE` appended so opencode places it at the
  end of the prompt (after the SKILL.md template). See the constant's
  docstring for why.
  """
  augmented = (arguments + CI_DIRECTIVE) if arguments else CI_DIRECTIVE.lstrip()
  prompt_label = f"--command {command} {_brief(augmented, 100)}"
  return _drive_loop(
    workspace,
    prompt_label,
    first_cmd=_build_cmd(model, command=command),
    first_input=augmented,
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

  Used by the smoke test — `opencode run --format json` with a trivial
  message. Same auto-yes loop semantics as `drive_command`; the only
  difference is the first turn has no `--command` flag.
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

  if shutil.which("opencode") is None:
    log("driver", "opencode not on PATH — bailing")
    run.exit_code = 127
    run.stderr_tail = "opencode binary not found on PATH"
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

      argv = [*next_cmd, next_input] if next_input else list(next_cmd)
      # opencode resolves the worktree root from `process.env.PWD ??
      # process.cwd()` (sst/opencode cli/cmd/run.ts). subprocess.Popen
      # sets the child's cwd but inherits the parent's PWD, so without
      # an explicit override opencode would walk up from pytest's cwd
      # (skills-evals/) instead of the workspace and find none of the
      # `.opencode/commands/` files x-x init wrote. The CI failure mode
      # was "Available commands: init, review, customize-opencode" —
      # only built-ins, because cfg.command was never populated.
      env = {**os.environ, "PWD": str(workspace)}
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
        log("driver", "opencode did not exit within 15s after stream end; killing")
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
      next_cmd = _build_cmd(model, resume=True)
      next_input = "yes"
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


def _build_cmd(
  model: str,
  *,
  command: str | None = None,
  resume: bool = False,
) -> list[str]:
  cmd = [
    "opencode", "run",
    "--format", "json",
    "--model", model,
    "--dangerously-skip-permissions",
  ]
  if resume:
    cmd.append("--continue")
  if command is not None:
    cmd.extend(["--command", command])
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
  part = event.get("part") or {}

  if etype == "text":
    txt = part.get("text") if isinstance(part, dict) else ""
    if isinstance(txt, str) and txt:
      return f"text={_brief(txt, 160)}"
    return f"text_empty raw={_brief(json.dumps(event), 240)}"

  if etype == "tool_use":
    tool = part.get("tool", "?") if isinstance(part, dict) else "?"
    state = part.get("state", {}) if isinstance(part, dict) else {}
    return (
      f"tool={tool} status={state.get('status', '?')} "
      f"input={_brief(json.dumps(state.get('input', {})), 100)}"
    )

  if etype == "reasoning":
    txt = part.get("text") if isinstance(part, dict) else ""
    return f"reasoning={_brief(txt or '', 100)}"

  if etype in ("step_start", "step_finish"):
    return (
      f"step_id={str(part.get('id', '?'))[:24]} "
      f"messageID={str(part.get('messageID', '-'))[:24]}"
    )

  if etype == "error":
    err = event.get("error") or {}
    return f"error={_brief(json.dumps(err) if isinstance(err, dict) else str(err), 200)}"

  return _brief(json.dumps(event), 200)


def _extract_text(event: dict) -> str:
  """Pull user-visible assistant text from one event, if any.

  Only `type: "text"` events count. `reasoning` is filtered out — it's
  the model's chain-of-thought and including it would let the
  auto-yes detector false-trigger on "yes" mentioned in thinking.
  """
  if "_raw" in event:
    return ""
  if event.get("type") != "text":
    return ""
  part = event.get("part")
  if not isinstance(part, dict):
    return ""
  txt = part.get("text")
  return txt if isinstance(txt, str) else ""


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
