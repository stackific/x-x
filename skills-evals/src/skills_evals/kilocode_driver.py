# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive a Kilo Code session non-interactively with auto-yes replies.

Kilo Code CLI is a fork of anomalyco/opencode (per
https://github.com/Kilo-Org/kilocode FAQ), so the wire-format and
command-resolution surface mirror `opencode_driver`. The differences
that matter for the eval loop:

1. **Binary name.** `kilo`, installed from `@kilocode/cli`.

2. **Permission bypass.** Kilo offers two non-interactive permission
   flags (per https://kilo.ai/docs/code-with-ai/platforms/cli-reference):
   `--dangerously-skip-permissions` (auto-approve non-denied permissions)
   and `--auto` (auto-approve ALL permissions). We pass `--auto` — the
   eval suite runs in a throwaway tmp_path workspace, so the broader
   bypass is safe and avoids the per-tool prompt that `--dangerously-skip-
   permissions` still raises when a tool sits on the deny-list.

3. **Slash commands resolve via `--command`.** Same mechanic as opencode:
   `kilo run --command x-plan <task>` resolves <name> against the skill
   registry (the parent x-x install writes `.claude/skills/x-plan/SKILL.md`
   with `name: x-plan`; per Kilo's docs Kilo discovers `.claude/skills/`
   in compat mode). The first parked attempt
   (https://github.com/stackific/x-x/pull/16) treated `/x-plan ...` as
   literal text and the agent never invoked the skill — switching to
   `--command` is the load-bearing fix this driver depends on.

4. **`--format json` event stream.** Inherited from opencode's wire
   format. Each line of stdout is one JSON event with type + part
   envelope; the parser is permissive about event shapes. Same
   types-of-interest as opencode (`text`, `tool_use`, `step_*`,
   `reasoning`, `error`); we only extract user-visible text from `text`
   events for the auto-yes detector.

5. **Multi-turn via `--continue`.** Each turn is a fresh subprocess; the
   next turn invokes `kilo run --continue --command x-plan` (or just
   `--continue`) to resume the prior session's context. Kilo's
   `--continue` "automatically finds the most recent session from the
   current workspace" (kilo.ai/docs/code-with-ai/platforms/cli).

6. **Working directory via `--dir`.** Opencode resolves cwd via
   `process.env.PWD ?? process.cwd()`; Kilo exposes an explicit `--dir`
   flag. We pass both `--dir <workspace>` and the env override so the
   skill registry walk anchors at the workspace regardless of the
   internal preference order.

Routing: Kilo's docs (kilo.ai/docs/code-with-ai/agents/custom-models)
specify that custom OpenAI-compatible providers require a
`kilo.json` / `kilo.jsonc` config file with provider stanza — there is
no env-var-only route for a custom baseURL. The workspace fixture in
conftest writes this file before the test runs; the driver does not
manage it. `DEEPSEEK_API_KEY` is read by Kilo at agent startup via the
`{env:DEEPSEEK_API_KEY}` substitution inside the config.

Non-interactive permission rules: same auto-yes mechanic as opencode.
The agent cannot raise a TUI prompt (--auto suppresses all permission
gates), so the SKILL.md's "Reply yes to proceed" checkpoints surface as
text and going idle. The driver keys off that text to send `yes` on the
next turn via `--continue`.

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

# Model format mirrors opencode's `provider/model` convention. The
# `openai-compatible` provider stanza in the workspace `kilo.json`
# declares `deepseek-v4-pro` as a model name; `kilo run --model
# openai-compatible/deepseek-v4-pro` selects it. See
# kilo.ai/docs/code-with-ai/agents/custom-models for the registration
# requirement (a model not declared in the config is rejected with a
# "model not found" error).
DEFAULT_MODEL = "openai-compatible/deepseek-v4-pro"

# Appended to the user task in `drive_command` so kilo places it at the
# tail of the prompt (after the SKILL.md template body kilo resolved
# from `--command <name>`). Last-instruction-wins in attention.
#
# Targets the two gates that strand sessions when the agent reaches a
# propose-or-clarify step in the SKILL.md flow:
#
#   1. Empty systems registry. `x-plan` SKILL.md Appendix C step 4 says
#      "STOP. Propose a new system to the user. On approval, add to
#      _data_systems.yaml. Then continue." The propose-and-wait wording
#      doesn't surface as `Reply yes` so the auto-yes regex misses it
#      and kilo goes idle.
#
#   2. Destructive overwrites in the executor. When `x-x` runs a plan
#      whose system already has an existing artifact (e.g. a reminders
#      plan that supersedes a todo plan, with the todo's index.html
#      already on disk), the model emits a checkpoint message like
#      "FYI: I'll review the whole plan with you at once" and goes
#      idle waiting for a `review per task` reply.
#
# Mirrors opencode_driver.CI_DIRECTIVE verbatim — kilo descends from
# opencode and shows the same gating behavior under DeepSeek routing.
# NOTE: must not begin with `-` / `--`. The string is passed as an argv
# element to `kilo run`, and yargs treats any element starting with
# `--` as a flag.
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
  "KILO_PROVIDER",
  "KILO_MODEL",
  "KILO_ORG_ID",
)
SECRET_ENV_KEYS = (
  "DEEPSEEK_API_KEY",
  "KILO_API_KEY",
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
  """Invoke `kilo run --command <command> <arguments>` then auto-yes.

  First turn spawns `kilo run --command <command>` with the task as
  the positional message. Subsequent turns spawn `kilo run --continue`
  with `yes` as the message until the agent stops asking for confirmation,
  the turn cap fires, or a subprocess exits non-zero.

  Arguments get `CI_DIRECTIVE` appended so kilo places it at the end of
  the prompt (after the SKILL.md template). See the constant's docstring
  for why.
  """
  augmented = (arguments + CI_DIRECTIVE) if arguments else CI_DIRECTIVE.lstrip()
  prompt_label = f"--command {command} {_brief(augmented, 100)}"
  return _drive_loop(
    workspace,
    prompt_label,
    first_cmd=_build_cmd(model, workspace, command=command),
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

  Used by the smoke test — `kilo run --format json` with a trivial
  message. Same auto-yes loop semantics as `drive_command`; the only
  difference is the first turn has no `--command` flag.
  """
  return _drive_loop(
    workspace,
    _brief(prompt, 100),
    first_cmd=_build_cmd(model, workspace),
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

  if shutil.which("kilo") is None:
    log("driver", "kilo not on PATH — bailing")
    run.exit_code = 127
    run.stderr_tail = "kilo binary not found on PATH"
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
      # Kilo (forked from opencode) resolves the worktree root from
      # `process.env.PWD ?? process.cwd()`. subprocess.Popen sets the
      # child's cwd but inherits the parent's PWD, so without an
      # explicit override kilo would walk up from pytest's cwd
      # (skills-evals/) instead of the workspace and find none of the
      # `.claude/skills/` files x-x init wrote. We also pass `--dir
      # <workspace>` in _build_cmd as a belt-and-suspenders.
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
        log("driver", "kilo did not exit within 15s after stream end; killing")
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
          f"kilo exited non-zero ({proc.returncode}); stopping. "
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
      next_cmd = _build_cmd(model, workspace, resume=True)
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
  workspace: Path,
  *,
  command: str | None = None,
  resume: bool = False,
) -> list[str]:
  cmd = [
    "kilo", "run",
    "--format", "json",
    "--model", model,
    "--auto",
    "--dir", str(workspace),
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

  for key in ECHOED_ENV_KEYS:
    log("driver", f"env {key}={os.environ.get(key, '(unset)')}")
  for key in SECRET_ENV_KEYS:
    val = os.environ.get(key)
    if val:
      log("driver", f"env {key}=set (length={len(val)}, ...{val[-4:]})")
    else:
      log("driver", f"env {key}=MISSING")

  cfg = workspace / "kilo.json"
  if cfg.is_file():
    log("driver", f"kilo.json present at {cfg} (size={cfg.stat().st_size})")
  else:
    log("driver", f"kilo.json NOT FOUND at {cfg} — routing will fail")


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
