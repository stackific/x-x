# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive a Cline CLI session non-interactively for one skill.

Cline's headless entry is `cline --yolo --json <prompt>`. YOLO mode
auto-approves every tool call (file edits, command execution, network
fetches), so a SKILL flow that would otherwise gate on per-tool review
runs end-to-end inside one process. `--json` switches stdout to NDJSON
events instead of styled text — one event per line, each parseable as
JSON, suitable for downstream tooling.

Multi-turn shape — cline exits when "the turn finishes" (cline 2026 docs
at docs.cline.bot/cli/cli-reference), where a turn ends when the agent
emits an `ask`-typed event (typically a "completion_result" subtype) or
runs out of work. The x-x and x-plan SKILL templates intersperse human
"Reply yes to proceed" gates inside one logical session, and a literal
read of those gates would have cline emit the question and exit, leaving
downstream gates unhandled. The CI directive appended in
`compose_skill_prompt` instructs the model to auto-approve every gate and
treat propose-or-clarify steps as informational — same pattern the
opencode driver uses, same rationale (no human is available in CI).

Routing: DeepSeek is a first-class cline provider as of cline's 2026
release stream. Credentials are seeded via `cline auth --provider
deepseek --apikey <key> --modelid deepseek-v4-pro` in the conftest's
workspace fixture so every test runs against a populated auth state
(sandboxed $HOME makes the auth state per-test). Per-invocation overrides
on `cline` itself stay minimal: `-c <workspace>` pins cwd, `-t 600` caps
the turn, `--json` enables structured output.

Slash commands: cline's `.clinerules/workflows/` directory becomes the
slash-command registry in interactive (TUI / VS Code) mode, but `cline
--yolo` is a headless one-shot — there's no chat surface to type a slash
into, and the prompt argument lands in front of the LLM verbatim. So
`drive_skill` inlines the SKILL.md body the same way the opencode driver
did before opencode's `--command` resolver landed (sst/opencode#2348):
read `<workspace>/.claude/skills/<skill>/SKILL.md`, concatenate with the
user task + CI directive, and pass as one prompt. `x-x init --agents
claude` (the transitional init value for cline; see
AGENT_INIT_VALUE_FOR_KEY) is what writes the SKILL.md files where this
helper reads them.

Logging: every state transition, every NDJSON event, every external
call gets a line on stderr via `_logging.log`. CI logs are the only
post-mortem surface.
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

DEFAULT_MAX_TURNS = 6
DEFAULT_PER_TURN_TIMEOUT_S = 900.0

# Appended to user task so cline's planner / executor LLM treats every
# SKILL.md gate as auto-approved. Without this the model legitimately
# emits "Reply yes to proceed" and ends the turn waiting for input —
# which never arrives in headless mode. Same role as the opencode
# driver's CI_DIRECTIVE; the wording is identical for cross-driver
# parity.
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

# Env vars echoed at startup for CI-log clarity. The cline CLI reads
# CLINE_DIR for its on-disk state root; the rest of the routing config
# is held in `cline auth`'s saved state file under that root.
ECHOED_ENV_KEYS = (
  "CLINE_DIR",
  "CLINE_SANDBOX",
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


SKILL_REL = Path(".claude") / "skills"


def _resolve_skill_path(workspace: Path, skill: str) -> Path:
  """Return the SKILL.md path under either project or user scope.

  `x-x init --scope project --agents claude` writes
  `<workspace>/.claude/skills/<skill>/SKILL.md`. `x-x init --scope user
  --agents claude` writes the same tree under `$HOME/.claude/skills/`.
  Both scopes are valid; we probe project first (workflow default) then
  fall back to $HOME so the user-scope workflow (X_X_INSTALL_SCOPE=user)
  resolves the same templates.
  """
  candidates = [
    workspace / SKILL_REL / skill / "SKILL.md",
    Path.home() / SKILL_REL / skill / "SKILL.md",
  ]
  for path in candidates:
    if path.is_file():
      return path
  raise FileNotFoundError(
    f"SKILL template not found at any of: {[str(p) for p in candidates]} "
    f"— did `x-x init --agents claude` run (in the workspace fixture) "
    f"before drive_skill was called?"
  )


def compose_skill_prompt(workspace: Path, skill: str, arguments: str) -> str:
  """Inline the SKILL.md body + user task + CI directive into one prompt.

  Matches the opencode driver's pre-`--command` strategy: cline has no
  native slash-resolver in headless mode, so the SKILL.md body is read
  off disk and prepended to the user task. `x-x init --agents claude`
  (the transitional init value for cline) is what placed the SKILL.md
  files; the helper above probes both project- and user-scope install
  locations so a single driver implementation serves both workflows.
  """
  skill_path = _resolve_skill_path(workspace, skill)
  body = skill_path.read_text(encoding="utf-8")
  task_block = f"\n\nUser task: {arguments}" if arguments else ""
  return f"SKILL TEMPLATE:\n\n{body}{task_block}{CI_DIRECTIVE}"


def seed_cline_auth(api_key: str | None = None) -> None:
  """Seed `cline auth` for the current $HOME so cline routes via DeepSeek.

  Used by both the workspace fixture (per-test, before the scenario
  drive_skill calls) and the smoke test (which uses a bare/ workspace
  outside the fixture). Without this seed, `cline --yolo --json` falls
  back to cline.bot's default account + qwen3.7-max model — which the
  CI runner is not authenticated for, surfacing as "Unauthorized" on
  the first call.

  `api_key` defaults to `DEEPSEEK_API_KEY` from env. Raises if neither
  the parameter nor the env var is populated.
  """
  api_key = api_key or os.environ.get("DEEPSEEK_API_KEY")
  if not api_key:
    raise RuntimeError(
      "DEEPSEEK_API_KEY not set; cannot seed cline auth"
    )
  log("driver", "seeding cline auth (provider=deepseek model=deepseek-v4-pro)")
  result = subprocess.run(
    [
      "cline", "auth",
      "--provider", "deepseek",
      "--apikey", api_key,
      "--modelid", "deepseek-v4-pro",
    ],
    capture_output=True, text=True,
  )
  if result.stdout.strip():
    for line in result.stdout.rstrip().splitlines():
      log("driver", f"cline auth stdout: {line}")
  if result.stderr.strip():
    for line in result.stderr.rstrip().splitlines():
      log("driver", f"cline auth stderr: {line}")
  if result.returncode != 0:
    raise RuntimeError(
      f"cline auth failed: exit={result.returncode}"
    )


def drive_skill(
  workspace: Path,
  skill: str,
  arguments: str = "",
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
) -> SkillRun:
  """Invoke a skill (x-plan / x-x) by inlining SKILL.md into the prompt."""
  prompt = compose_skill_prompt(workspace, skill, arguments)
  return _drive_loop(
    workspace,
    initial_label=f"skill={skill} {_brief(arguments, 80)}",
    initial_prompt=prompt,
    max_turns=max_turns,
    per_turn_timeout=per_turn_timeout,
    transcript_path=transcript_path,
  )


def drive_prompt(
  workspace: Path,
  prompt: str,
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
) -> SkillRun:
  """Send a raw prompt (no SKILL inline). Used by the smoke test."""
  return _drive_loop(
    workspace,
    initial_label=_brief(prompt, 80),
    initial_prompt=prompt,
    max_turns=max_turns,
    per_turn_timeout=per_turn_timeout,
    transcript_path=transcript_path,
  )


def _drive_loop(
  workspace: Path,
  *,
  initial_label: str,
  initial_prompt: str,
  max_turns: int,
  per_turn_timeout: float,
  transcript_path: Path | None,
) -> SkillRun:
  run = SkillRun(workspace=workspace, initial_prompt=initial_label)
  _log_startup(workspace, initial_label, max_turns, per_turn_timeout)

  if shutil.which("cline") is None:
    log("driver", "cline not on PATH — bailing")
    run.exit_code = 127
    run.stderr_tail = "cline binary not found on PATH"
    return run

  loop_start = time.time()
  next_prompt = initial_prompt
  resume = False

  for turn_idx in range(max_turns):
    cmd = _build_cmd(workspace, resume=resume, per_turn_timeout=per_turn_timeout)
    log(
      "driver",
      f"turn {turn_idx + 1}/{max_turns} spawn: {' '.join(cmd)} -- "
      f"{_brief(next_prompt, 120)}",
    )
    log("driver", f"cwd: {workspace}")

    argv = [*cmd, next_prompt]
    proc = subprocess.Popen(
      argv,
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

    turn_text_chunks: list[str] = []
    turn_start = time.time()
    timed_out = False

    while True:
      try:
        line = out_q.get(timeout=per_turn_timeout)
      except queue.Empty:
        timed_out = True
        log(
          "driver",
          f"TIMEOUT after {per_turn_timeout}s waiting for next event on "
          f"turn {turn_idx + 1} (events seen this turn: "
          f"{len(turn_text_chunks)}, elapsed since spawn: "
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
      log("driver", "cline did not exit within 15s after stream end; killing")
      proc.kill()
      proc.wait(timeout=5)
    run.exit_code = proc.returncode
    run.stderr_tail = "\n".join(err_lines[-40:])
    run.turns += 1
    run.timed_out = timed_out

    log(
      "driver",
      f"turn {turn_idx + 1} ended: exit={proc.returncode} "
      f"text_chunks={len(turn_text_chunks)} timed_out={timed_out} "
      f"elapsed={time.time() - turn_start:.1f}s",
    )

    if timed_out:
      break
    if proc.returncode != 0:
      log(
        "driver",
        f"cline exited non-zero ({proc.returncode}); stopping. "
        f"stderr tail:\n{run.stderr_tail}",
      )
      break

    final_text = "\n".join(turn_text_chunks)
    if not _asks_for_confirmation(final_text):
      log("driver", "no confirmation prompt in final text — session done")
      run.completed = True
      break

    log("driver", "confirmation prompt detected; queueing 'yes' for next turn")
    next_prompt = "yes"
    resume = True
    run.yes_replies += 1
  else:
    log("driver", f"hit max_turns={max_turns} loop cap")

  log(
    "driver",
    f"drive done: turns={run.turns} yes_replies={run.yes_replies} "
    f"events={run.events_received} completed={run.completed} "
    f"timed_out={run.timed_out} exit_code={run.exit_code} "
    f"elapsed={time.time() - loop_start:.1f}s",
  )

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  return run


def _build_cmd(
  workspace: Path,
  *,
  resume: bool,
  per_turn_timeout: float,
) -> list[str]:
  """Assemble the `cline` argv (without the trailing prompt).

  --yolo: skip tool-approval prompts (cline auto-approves every action).
  --json: NDJSON event stream instead of styled text.
  -c <ws>: pin the working directory so cline doesn't walk up from
           pytest's cwd looking for project state.
  -t <s>: per-turn timeout in seconds. We pass a value higher than the
          driver's own per_turn_timeout so the driver's queue read times
          out first and we control the kill semantics.
  --resume: cline's flag for picking up the most-recent session; used
            on follow-up turns when we need to feed a "yes" past a
            stranded gate.
  """
  cmd = [
    "cline",
    "--yolo",
    "--json",
    "-c", str(workspace),
    "-t", str(int(per_turn_timeout) + 60),
  ]
  if resume:
    cmd.append("--resume")
  return cmd


def _log_startup(
  workspace: Path,
  initial_label: str,
  max_turns: int,
  per_turn_timeout: float,
) -> None:
  log("driver", f"drive called: workspace={workspace}")
  log("driver", f"initial: {initial_label}")
  log(
    "driver",
    f"max_turns={max_turns} per_turn_timeout={per_turn_timeout}s",
  )

  cline_path = shutil.which("cline")
  log("driver", f"cline on PATH: {cline_path}")
  if cline_path:
    try:
      out = subprocess.run(
        ["cline", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"cline --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"cline --version failed: {e}")

  for key in ECHOED_ENV_KEYS:
    log("driver", f"env {key}={os.environ.get(key, '(unset)')}")
  for key in SECRET_ENV_KEYS:
    val = os.environ.get(key)
    if val:
      log("driver", f"env {key}=set (length={len(val)}, ...{val[-4:]})")
    else:
      log("driver", f"env {key}=MISSING")


def _parse_event(line: str) -> dict:
  """Parse one NDJSON event; fall back to a raw envelope on errors."""
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
  text = event.get("text") or ""
  subtype = event.get("say") or event.get("ask") or ""

  if etype in ("say", "ask"):
    return f"subtype={subtype} text={_brief(text, 160)}"
  return _brief(json.dumps(event), 200)


def _extract_text(event: dict) -> str:
  """Pull user-visible assistant text from one event.

  Cline's NDJSON shape (per docs.cline.bot/cli/cli-reference, 2026):
    {"type": "say" | "ask", "text": "...", "ts": <ms>,
     "say" | "ask": "<subtype>", "reasoning": "...", "partial": <bool>}

  Only `type: "say"` events surface user-visible assistant text. `ask`
  events are confirmation gates; their text is matched separately by
  `_asks_for_confirmation`. `reasoning` is internal chain-of-thought —
  including it would let the auto-yes detector false-trigger on "yes"
  mentioned inside the model's thinking.
  """
  if "_raw" in event:
    return ""
  if event.get("type") != "say":
    return ""
  text = event.get("text")
  return text if isinstance(text, str) else ""


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
