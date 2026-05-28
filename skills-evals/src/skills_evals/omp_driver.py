# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive an omp (oh-my-pi) session non-interactively for one skill.

omp's `-p` / `--print` mode is single-shot: one process per turn, send the
message as a positional argv, read events on stdout, exit when the agent
goes idle. There is no documented stdin-based multi-turn protocol (the
Claude analog), and there is no upfront `--command <name>` resolver (the
OpenCode analog). What omp does have is a `--continue` flag that resumes
the most recently closed local session, plus a `--mode json` flag that
makes stdout an NDJSON event stream instead of the final-assistant-text
blob `--mode text` emits.

So the driver shape mirrors the Copilot driver (single-shot + auto-yes
continuation loop), not the OpenCode driver (single-process + stream-json
in via stdin), with the OpenCode-style event parsing on top.

Slash-command form: skills land in omp as `/skill:<name>` slash commands,
not `/<name>`. The bundled `scope` skill ships in `.claude/skills/scope/
SKILL.md` with `name: scope` in its frontmatter; omp's claude.ts
discovery loads it and `getSkillSlashCommandName(skill)` in
`packages/coding-agent/src/extensibility/skills.ts` registers it under
the name `skill:scope`. Invoking it from the CLI is therefore
`omp -p "/skill:scope <task>"` — sending `/scope ...` would land as
literal text and the LLM would hallucinate a missing command.

Flags exercised (all documented in `packages/coding-agent/src/cli/args.ts`
and the launch command help):
  -p / --print            Non-interactive: process the prompt and exit.
  --mode json             NDJSON event stream on stdout (every event on
                          its own line). Default `text` would print only
                          the final assistant text, which kills the
                          auto-yes detector and breaks the smoke test's
                          events_received count.
  --auto-approve / --yolo Skip every tool approval prompt. Same as
                          `--approval-mode yolo`. Without it, the agent
                          stalls on first write/edit/bash in non-TTY mode.
  --continue              Resume the previous session (cwd-rooted, see
                          session-manager.ts). Used on every turn after
                          the first to deliver the `yes` reply against
                          the same workspace transcript.
  --no-rules              Don't load user-level rules. Eval workspaces
                          should be hermetic — rules from $HOME could
                          flip behavior between machines.
  --no-title              Skip the title auto-generation LLM call. Saves
                          one round-trip per session for no eval value.
  --model deepseek/deepseek-v4-pro
                          Models.dev-style provider/model id. omp ships
                          a built-in `deepseek` provider catalog (see
                          provider-models/descriptors.ts catalogDescriptor
                          "deepseek"), so DEEPSEEK_API_KEY routes directly.

Routing: omp reads DEEPSEEK_API_KEY for the built-in `deepseek` provider
via Models.dev (same env-var single-secret pattern as OpenCode). The
auto-detected DeepSeek compat (openai-completions-compat.ts) handles the
reasoning_content round-trip, max_tokens override, and reasoningEffortMap
xhigh→max quirks transparently.

Logging policy is identical to the Claude / Copilot drivers: every state
transition, every external call, every line of stderr lands on stderr
via `_logging.log`. CI logs are the only post-mortem surface.
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

# Appended to the user task so omp lands it at the tail of the prompt.
# Same shape as opencode_driver.CI_DIRECTIVE — omp's `/skill:<name>`
# expansion appends the user args at the end of the SKILL.md template
# body (expandSlashCommand → appendInlineArgsFallback when the template
# has no `$ARGUMENTS` placeholder), so this directive lands after the
# SKILL template and benefits from last-instruction-wins attention.
#
# Without it, the first eval runs stranded on:
#
#   1. Empty `_data_systems.yaml` — scope SKILL.md Appendix C step 4
#      says "STOP. Propose a new system to the user. On approval, add
#      to _data_systems.yaml. Then continue." The propose-and-wait
#      wording doesn't always surface as `Reply yes` so the auto-yes
#      regex misses it and omp goes idle.
#
#   2. Destructive-overwrite checkpoints in /ship — when a plan would
#      replace an existing artifact (e.g. reminders.html on top of
#      todo.html), the model emits a meta-message ("FYI: I'll review
#      the whole plan with you at once") and goes idle waiting for
#      review-per direction.
#
# Mirrors the same constant in claude_driver / opencode_driver / copilot_driver.
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

# Echoed at driver startup so CI logs show exactly which backend omp is
# routed to. Non-secret values print in full; secrets are masked.
ECHOED_ENV_KEYS = (
  "OMP_MODEL",
  "PI_SMOL_MODEL",
  "PI_SLOW_MODEL",
  "PI_PLAN_MODEL",
)
SECRET_ENV_KEYS = ("DEEPSEEK_API_KEY",)


@dataclass
class SkillRun:
  """Mirror of the other drivers' SkillRun for cross-driver parity.

  Field semantics:
    - `turns` counts omp invocations (initial + each `--continue` reply).
    - `yes_replies` counts how often the driver fed "yes" through a gate.
    - `events_received` counts parsed NDJSON events across all turns.
    - `transcript` holds parsed event dicts. Turn boundaries land as
      `{"_turn": N}` sentinel entries so a post-mortem can tell which
      events came from which invocation.
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
  """Run one skill in `workspace`, auto-resuming on "Reply yes" gates.

  Turn 1: `omp -p --mode json --auto-approve --model <model> <prompt>`,
  with CI_DIRECTIVE appended to the prompt when the prompt is a slash
  command (it lands after the expanded SKILL template body).

  Turns 2..max_turns: `omp --continue -p --mode json --auto-approve yes`
  to resume the previous session and reply yes — but only when the
  previous turn's text output matched the "Reply yes" gate pattern.
  Otherwise the loop exits cleanly.
  """
  if max_turns < 1:
    raise ValueError(f"max_turns must be >= 1, got {max_turns}")

  augmented_prompt = _augment_prompt(initial_prompt)
  run = SkillRun(workspace=workspace, initial_prompt=augmented_prompt)
  _log_startup(workspace, augmented_prompt, per_turn_timeout, max_turns, model)

  if shutil.which("omp") is None:
    log("driver", "omp not on PATH — bailing")
    run.exit_code = 127
    run.stderr_tail = "omp binary not found on PATH"
    return run

  loop_start = time.time()
  turn_prompt = augmented_prompt
  use_continue = False

  while run.turns < max_turns:
    run.transcript.append({"_turn": run.turns + 1})
    turn_events, turn_text, exit_code, stderr_tail, timed_out = _run_one_turn(
      workspace,
      turn_prompt,
      per_turn_timeout=per_turn_timeout,
      use_continue=use_continue,
      model=model,
    )
    run.transcript.extend(turn_events)
    run.events_received += len(turn_events)
    run.turns += 1
    run.exit_code = exit_code
    run.stderr_tail = stderr_tail
    if timed_out:
      run.timed_out = True
      log("driver", f"turn {run.turns} TIMED OUT — abandoning continuation loop")
      break
    if exit_code != 0:
      log(
        "driver",
        f"turn {run.turns} exited {exit_code} — abandoning continuation loop. "
        f"stderr tail:\n{stderr_tail}",
      )
      break

    stream_error = _detect_stream_error(turn_events)
    if stream_error is not None:
      # omp exits 0 even when the LLM call 402s — `stopReason: "error"`
      # is the only hint we get. Flip the exit_code to non-zero so the
      # downstream `assert run.exit_code == 0` in scenario tests reports
      # the upstream cause directly instead of failing much later on
      # `assert len(plans) == 2, got 0`.
      log("driver", f"turn {run.turns} ended with LLM error: {stream_error}")
      run.exit_code = 1
      run.stderr_tail = (run.stderr_tail + "\n" + stream_error).strip()
      break

    if not _asks_for_confirmation(turn_text):
      log("driver", f"turn {run.turns} ended without 'Reply yes' gate — session done")
      run.completed = True
      break

    log("driver", f"turn {run.turns} ended at 'Reply yes' gate — resuming with --continue")
    run.yes_replies += 1
    turn_prompt = "yes"
    use_continue = True
  else:
    # while-else fires when the loop's condition (turns < max_turns) becomes
    # false without a break — surfaces the turn cap loudly instead of
    # masking it as "completed".
    log("driver", f"hit max_turns={max_turns} with the gate still firing — stopping")

  log(
    "driver",
    f"drive_skill done: turns={run.turns} yes_replies={run.yes_replies} "
    f"events={run.events_received} exit_code={run.exit_code} "
    f"completed={run.completed} timed_out={run.timed_out} "
    f"elapsed={time.time() - loop_start:.1f}s",
  )

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  return run


def _augment_prompt(prompt: str) -> str:
  """Append CI_DIRECTIVE so it lands after omp's slash-command expansion.

  For a slash command like `/skill:scope <task>`, omp's
  expandSlashCommand substitutes the SKILL.md body and appends the user
  args via appendInlineArgsFallback when no `$ARGUMENTS` placeholder is
  present. So an argument string of `<task> + CI_DIRECTIVE` lands at the
  tail of the prompt, where last-instruction-wins attention picks it up.

  For raw prompts (smoke test), the directive just gets appended.
  """
  if prompt.startswith("/"):
    # Split into head ("/skill:scope") and rest ("<task>"); append
    # CI_DIRECTIVE to the rest so it survives slash expansion.
    space_idx = prompt.find(" ")
    if space_idx == -1:
      return prompt + " " + CI_DIRECTIVE.lstrip()
    head, args = prompt[:space_idx], prompt[space_idx + 1:]
    return f"{head} {args}{CI_DIRECTIVE}"
  return prompt + CI_DIRECTIVE


def _run_one_turn(
  workspace: Path,
  prompt: str,
  *,
  per_turn_timeout: float,
  use_continue: bool,
  model: str,
) -> tuple[list[dict], str, int | None, str, bool]:
  """Spawn one `omp` invocation; return (events, text, exit, stderr, timed_out).

  Each call is a fresh subprocess — omp's `-p` mode is single-shot per
  invocation. `use_continue=True` adds `--continue` so the process
  resumes the previous session's conversation history.
  """
  cmd = ["omp"]
  if use_continue:
    cmd.append("--continue")
  cmd.extend([
    "-p",
    "--mode", "json",
    "--auto-approve",
    "--no-rules",
    "--no-title",
    "--model", model,
  ])
  cmd.append(prompt)

  log(
    "driver",
    f"spawn: omp ... --continue={use_continue} model={model} "
    f"prompt={_brief(prompt, 200)}",
  )
  log("driver", f"cwd: {workspace}")

  # omp resolves cwd from process.env.PWD ?? process.cwd() in some paths
  # (mirrors the opencode driver caveat). Setting PWD explicitly aligns
  # whichever path omp uses on the active platform.
  env = {**os.environ, "PWD": str(workspace)}
  proc = subprocess.Popen(
    cmd,
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

  events: list[dict] = []
  text_chunks: list[str] = []
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
          f"TIMEOUT after {per_turn_timeout}s waiting for next event "
          f"(events this turn: {len(events)}, "
          f"elapsed: {time.time() - turn_start:.1f}s)",
        )
        proc.kill()
        break

      if line is None:
        log(
          "driver",
          f"stdout EOF (omp exited); events this turn: {len(events)}",
        )
        break
      if not line.strip():
        continue

      event = _parse_event(line)
      events.append(event)
      _log_event(event, len(events))

      text = _extract_text(event)
      if text:
        text_chunks.append(text)
  finally:
    try:
      proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
      log("driver", "omp did not exit within 15s after stream end; killing")
      proc.kill()
      proc.wait(timeout=5)

  stderr_tail = "\n".join(err_lines[-40:])
  text = "\n".join(text_chunks)
  log(
    "driver",
    f"turn done: exit={proc.returncode} events={len(events)} "
    f"text_chunks={len(text_chunks)} timed_out={timed_out} "
    f"elapsed={time.time() - turn_start:.1f}s",
  )
  return events, text, proc.returncode, stderr_tail, timed_out


def _log_startup(
  workspace: Path,
  initial_prompt: str,
  per_turn_timeout: float,
  max_turns: int,
  model: str,
) -> None:
  log("driver", f"drive_skill called: workspace={workspace}")
  log("driver", f"initial_prompt: {_brief(initial_prompt, 240)}")
  log(
    "driver",
    f"per_turn_timeout={per_turn_timeout}s max_turns={max_turns} model={model}",
  )

  omp_path = shutil.which("omp")
  log("driver", f"omp on PATH: {omp_path}")
  if omp_path:
    try:
      out = subprocess.run(
        ["omp", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"omp --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"omp --version failed: {e}")

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

  Unparseable lines land in the transcript verbatim under a `_raw` key so
  post-hoc inspection can still see what came across the wire.
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
  """One-line summary of an event for CI debug surface.

  omp emits one event per stream chunk on stdout when `--mode json` is
  set: `session`, `agent_start`, `turn_start`/`turn_end`, `message_start`
  (assistant or user), a flurry of `message_update` carrying
  `thinking_delta`/`text_delta`/`toolcall_*` events, and a closing
  `message_end` with the consolidated message. The summarizer covers the
  shapes that carry information the auto-yes detector cares about
  (`message_end` final assistant text, error signals) and falls back to
  a bounded JSON dump for everything else so a wire-format regression is
  visible without crashing the driver.
  """
  if "_raw" in event:
    return _brief(event["_raw"], 200)
  if "_turn" in event:
    return f"--- driver turn {event['_turn']} ---"

  etype = event.get("type")

  if etype == "message_end":
    msg = event.get("message") or {}
    role = msg.get("role", "?") if isinstance(msg, dict) else "?"
    stop_reason = msg.get("stopReason", "?") if isinstance(msg, dict) else "?"
    content = msg.get("content") if isinstance(msg, dict) else None
    text = ""
    tool_names: list[str] = []
    if isinstance(content, list):
      for item in content:
        if not isinstance(item, dict):
          continue
        if item.get("type") == "text":
          t = item.get("text")
          if isinstance(t, str):
            text += t
        elif item.get("type") == "toolCall":
          name = item.get("name")
          if isinstance(name, str):
            tool_names.append(name)
    return (
      f"role={role} stopReason={stop_reason} tools={tool_names} "
      f"text={_brief(text, 160)}"
    )

  if etype in ("turn_start", "turn_end", "agent_start", "session"):
    return _brief(json.dumps({k: v for k, v in event.items() if k != "type"}), 120)

  if etype == "message_update":
    inner = event.get("assistantMessageEvent") or {}
    inner_type = inner.get("type", "?") if isinstance(inner, dict) else "?"
    delta = inner.get("delta") if isinstance(inner, dict) else None
    if isinstance(delta, str):
      return f"update {inner_type} delta={_brief(delta, 80)}"
    return f"update {inner_type}"

  if etype == "error":
    err = event.get("error") or event.get("message") or {}
    return f"error={_brief(json.dumps(err) if isinstance(err, dict) else str(err), 200)}"

  return _brief(json.dumps(event), 200)


def _extract_text(event: dict) -> str:
  """Pull user-visible assistant text from one event, if any.

  Source of truth is `type: "message_end"` with `message.role:
  "assistant"` — this carries the consolidated final assistant message
  with the full `content[]` array. Iterating `text_end` / `text_delta`
  events would also work but multiplies the chance of double-counting
  text already present in the message_end. Filtering on content type
  drops `thinking` (chain-of-thought) and `toolCall` items so the
  auto-yes detector doesn't false-trigger on "yes" mentioned inside
  reasoning text or in a tool argument.
  """
  if "_raw" in event or "_turn" in event:
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
    if isinstance(item, dict) and item.get("type") == "text":
      t = item.get("text")
      if isinstance(t, str):
        parts.append(t)
  return "\n".join(parts)


def _detect_stream_error(events: list[dict]) -> str | None:
  """Return a human-readable error if the LLM call ended in error.

  omp's print mode exits 0 even when the underlying model call returns a
  402 / 429 / 500 — the failure surfaces only as `stopReason: "error"`
  on the last assistant message_end with an empty content[] and an
  `errorMessage` field. Without this check the driver reports the run
  as `completed` and the scenario test fails much later with the
  cryptic "got 0 plan files" — masking the upstream cause.
  """
  for event in reversed(events):
    if not isinstance(event, dict):
      continue
    if event.get("type") != "message_end":
      continue
    msg = event.get("message")
    if not isinstance(msg, dict):
      continue
    if msg.get("role") != "assistant":
      continue
    stop_reason = msg.get("stopReason")
    if stop_reason == "error":
      err_msg = msg.get("errorMessage") or msg.get("error") or "(no errorMessage field)"
      return f"assistant message_end stopReason=error errorMessage={_brief(str(err_msg), 240)}"
    # Found the last assistant message, no error.
    return None
  return None


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
