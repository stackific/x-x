# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Drive a GitHub Copilot CLI session non-interactively for one skill.

GitHub Copilot CLI's non-interactive mode is single-shot: `copilot -p
"<prompt>"` runs the prompt to completion and exits. Unlike Claude Code's
`--input-format stream-json` (which keeps one process alive for the whole
multi-turn session), there is no documented stay-alive-and-stream protocol
for Copilot CLI as of May 2026 — see the public reference at
docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference
and the issue tracking missing stream output in CI:
github.com/github/copilot-cli/issues/1181.

What this means for the auto-yes mechanic the stax skills rely on:

The ship and scope skills pause at "Reply `yes` to proceed" gates. We
originally hoped `--no-ask-user` would replace the auto-yes loop, but
empirical evidence from the first manual eval run shows it's a hint,
not a hard constraint: the agent decides per-turn whether to honor the
gate. Run 26432641287 had three of four turns proceed autonomously and
one stop dead at "Reply yes" — workspace state goes wrong, downstream
turns see an empty `.stax/`.

The fix is a continuation loop modeled on the Claude driver: when one
turn ends with the "Reply yes" prompt in its captured stdout, run
`copilot --continue -p "yes"` to resume the same session and let the
agent move past the gate. `--continue` picks up the most recently
closed local session for the user (per the Copilot CLI reference) —
safe here because the eval suite runs sequentially.

Flags exercised (all documented in the reference above):
  -p <prompt>          Run the prompt non-interactively and exit.
  -s                   Silent: suppress session metadata, output only the
                       agent's response. Without -s, Copilot prints stats
                       and decoration to stdout that pollute the
                       "Reply yes" pattern match and the smoke test's
                       events_received count.
  --continue           Resume the most recently closed local session.
  -C <dir>             Override the session's saved working directory on
                       --continue. Per the May 2026 release notes,
                       --continue now resumes in the session's saved cwd
                       by default; -C makes the intended cwd explicit
                       and avoids relying on the resume default.
  --allow-all-tools    Skip per-tool permission prompts.
  --no-ask-user        Prevent the agent from asking clarifying questions
                       (best-effort — see note above).
  --add-dir <dir>      Add a directory to the allowed-paths list.
  --model <id>         Pick the model (we route to deepseek-v4-pro via the
                       Anthropic-compatible BYOK env vars below).

Routing for BYOK / DeepSeek is done via env vars set in conftest, not
flags — COPILOT_PROVIDER_TYPE=anthropic, COPILOT_PROVIDER_BASE_URL=
https://api.deepseek.com/anthropic, COPILOT_PROVIDER_API_KEY, COPILOT_MODEL.

Provider type MUST be `anthropic` (not `openai`) — DeepSeek requires
reasoning_content echo-back on subsequent requests, which Copilot CLI's
OpenAI integration does not support. The Anthropic Messages wire avoids
the issue.

Logging policy (non-negotiable, same as the Claude driver): every state
transition, every external call, every line of the agent's stderr lands
on stderr via `_logging.log`. CI logs are the only post-mortem surface.
"""

from __future__ import annotations

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

DEFAULT_MAX_TURNS = 10
DEFAULT_PER_TURN_TIMEOUT_S = 600.0

# Copilot CLI's `-p <prompt>` does NOT resolve leading slash commands the
# way Claude Code does — `copilot -p "/scope build an X"` is passed to
# the model verbatim, and the model treats it as a literal request to
# "build an X" rather than an invocation of the scope skill on disk.
# Empirical evidence: run 26618829987 (copilot user-scope, fix branch)
# showed `Done. Created \`todo.html\`` as the first stdout line for a
# `/scope build a single HTML and localStorage-based todo list app`
# prompt — the scope planning step was skipped entirely, no work-item
# plan files were created, every downstream judge then fails with
# "expected exactly N work-item files, got 0".
#
# Workaround mirrors the cline driver's `compose_skill_prompt` pattern
# (which itself dates back to the opencode driver's pre-`--command`
# era): when the test prompt begins with `/scope ` or `/ship`, read
# the corresponding SKILL.md off disk, prepend its body to the
# prompt, append the same CI directive every other inlining driver
# uses, and hand the whole composed text to `copilot -p`. The agent
# then sees the actual skill instructions inline and follows them
# instead of treating the slash as ornamental.
#
# Paths probed below mirror the copilot agent's documented skill
# discovery list (constants.go: `.agents/skills/`, `.claude/skills/`,
# `.github/skills/` at project scope; `~/.copilot/skills/`,
# `~/.agents/skills/` at user scope) plus `~/.claude/skills/` because
# copilot tests install via `stax init --agents claude` (the
# transitional shape — see conftest's AGENT_INIT_VALUE_FOR_KEY) which
# lands skills under `.claude/skills/`.
SKILL_CANDIDATE_RELS = (
  Path(".claude") / "skills",
  Path(".agents") / "skills",
  Path(".github") / "skills",
)
SKILL_USER_CANDIDATE_RELS = (
  Path(".claude") / "skills",
  Path(".agents") / "skills",
  Path(".copilot") / "skills",
)

# Verbatim copy of cline_driver.CI_DIRECTIVE — kept verbatim, not
# imported, because each driver's docstring asserts cross-driver parity
# is by-value and an import would couple the modules in a way that hides
# accidental drift in code review.
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

# Matches `/scope ARGS`, `/ship ARGS`, `/scope`, `/ship` at the very
# start of the prompt. The skill name is group 1, arguments (may be
# empty) are group 2 with the leading whitespace stripped.
_SLASH_RE = re.compile(r"^/(?P<skill>scope|ship)(?:\s+(?P<args>.*))?$", re.DOTALL)

# Echoed at driver startup so CI logs show exactly which backend Copilot
# is routed to. Non-secret values are printed in full; secrets are masked.
ECHOED_ENV_KEYS = (
  "COPILOT_PROVIDER_TYPE",
  "COPILOT_PROVIDER_BASE_URL",
  "COPILOT_MODEL",
  "COPILOT_PROVIDER_MAX_PROMPT_TOKENS",
  "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS",
  "COPILOT_OFFLINE",
)
SECRET_ENV_KEYS = (
  "COPILOT_PROVIDER_API_KEY",
  "DEEPSEEK_API_KEY",
  "COPILOT_GITHUB_TOKEN",
  "GH_TOKEN",
)


@dataclass
class SkillRun:
  """Mirror of claude_driver.SkillRun for cross-driver test parity.

  Field semantics:
    - `turns` counts Copilot invocations (initial + each `--continue` reply).
    - `yes_replies` counts how often the driver had to feed "yes" to a
      gate the agent emitted despite `--no-ask-user`.
    - `events_received` counts stdout lines across all turns.
    - `transcript` holds raw stdout lines wrapped in `{"line": "..."}`
      dicts. Turn boundaries are marked with sentinel
      `{"line": "--- turn N ---"}` entries so the post-mortem can tell
      which output came from which invocation.
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
      for entry in self.transcript:
        line = entry.get("line", "")
        f.write(line + "\n")


def _resolve_skill_path(workspace: Path, skill: str) -> Path | None:
  """Return the SKILL.md path for `skill` if present at any documented
  copilot discovery location, else None.

  Project-scope candidates rooted in `workspace`; user-scope candidates
  rooted in `$HOME`. Order matches the project-then-user preference the
  cline driver uses — project install wins when both are seeded, which
  matches `stax init`'s default scope and the workflow's default
  STAX_INSTALL_SCOPE=project.
  """
  candidates: list[Path] = [
    workspace / rel / skill / "SKILL.md" for rel in SKILL_CANDIDATE_RELS
  ]
  candidates.extend(
    Path.home() / rel / skill / "SKILL.md"
    for rel in SKILL_USER_CANDIDATE_RELS
  )
  for path in candidates:
    if path.is_file():
      return path
  log(
    "driver",
    f"SKILL.md for '{skill}' not found at any of: "
    f"{[str(p) for p in candidates]}",
  )
  return None


def compose_skill_prompt(workspace: Path, skill: str, arguments: str) -> str:
  """Inline the SKILL.md body + user task + CI directive into one prompt.

  Same shape as cline_driver.compose_skill_prompt. The body is read off
  disk so the workspace's actual installed SKILL.md is what the agent
  follows — including any per-scope edits a user has made.
  """
  skill_path = _resolve_skill_path(workspace, skill)
  if skill_path is None:
    raise FileNotFoundError(
      f"copilot driver could not locate SKILL.md for '{skill}' in "
      f"workspace={workspace} or $HOME — did `stax init` run before "
      f"drive_skill was called?"
    )
  body = skill_path.read_text(encoding="utf-8")
  task_block = f"\n\nUser task: {arguments}" if arguments else ""
  return f"SKILL TEMPLATE:\n\n{body}{task_block}{CI_DIRECTIVE}"


def _maybe_inline_skill(workspace: Path, prompt: str) -> str:
  """Inline SKILL.md when `prompt` begins with `/scope` or `/ship`.

  Returns the inlined prompt on a match, the original prompt otherwise.
  Non-slash prompts (e.g. the smoke test's `Respond with the single
  word: ok`) pass through unchanged so the no-skill code path keeps
  working.
  """
  m = _SLASH_RE.match(prompt.strip())
  if m is None:
    return prompt
  skill = m.group("skill")
  args = (m.group("args") or "").strip()
  composed = compose_skill_prompt(workspace, skill, args)
  log(
    "driver",
    f"inlined SKILL.md for /{skill}: "
    f"args={_brief(args, 80)!r} composed_len={len(composed)}",
  )
  return composed


def drive_skill(
  workspace: Path,
  initial_prompt: str,
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
) -> SkillRun:
  """Run one skill in `workspace`, auto-resuming on "Reply yes" gates.

  Turn 1: `copilot -p <initial_prompt> --allow-all-tools --no-ask-user`.
  Turns 2..max_turns: `copilot --continue -p yes --allow-all-tools
  --no-ask-user`, but only when the previous turn's stdout matched
  the "Reply yes" gate pattern. Otherwise the loop exits.

  When `initial_prompt` begins with `/scope` or `/ship`, the
  corresponding SKILL.md is inlined into the prompt (see the
  module-level docstring on _SLASH_RE and SKILL_CANDIDATE_RELS for the
  rationale). The recorded `run.initial_prompt` stays the original
  slash form so transcripts and logs read the way the test author
  wrote them — the inlined body would otherwise dominate every log
  line.
  """
  if max_turns < 1:
    raise ValueError(f"max_turns must be >= 1, got {max_turns}")

  run = SkillRun(workspace=workspace, initial_prompt=initial_prompt)
  _log_startup(workspace, initial_prompt, per_turn_timeout, max_turns)

  effective_prompt = _maybe_inline_skill(workspace, initial_prompt)
  loop_start = time.time()
  turn_prompt = effective_prompt
  use_continue = False

  while run.turns < max_turns:
    run.transcript.append({"line": f"--- turn {run.turns + 1} ---"})
    turn_output, exit_code, stderr_tail, timed_out = _run_one_turn(
      workspace,
      turn_prompt,
      per_turn_timeout=per_turn_timeout,
      use_continue=use_continue,
    )
    for line in turn_output:
      run.transcript.append({"line": line})
    run.events_received += len(turn_output)
    run.turns += 1
    run.exit_code = exit_code
    run.stderr_tail = stderr_tail
    if timed_out:
      run.timed_out = True
      log(
        "driver",
        f"turn {run.turns} TIMED OUT — abandoning continuation loop",
      )
      break
    if exit_code != 0:
      log(
        "driver",
        f"turn {run.turns} exited {exit_code} — abandoning continuation loop",
      )
      break

    last_text = "\n".join(turn_output[-40:])
    if not _asks_for_confirmation(last_text):
      log(
        "driver",
        f"turn {run.turns} ended without 'Reply yes' gate — session done",
      )
      run.completed = True
      break

    log(
      "driver",
      f"turn {run.turns} ended at 'Reply yes' gate — resuming with --continue",
    )
    run.yes_replies += 1
    turn_prompt = "yes"
    use_continue = True
  else:
    # while-else fires when the loop's condition (turns < max_turns)
    # becomes false without a break. We hit the turn cap while the agent
    # was still gating — surface that loudly, not silently as "completed".
    log(
      "driver",
      f"hit max_turns={max_turns} with the gate still firing — stopping",
    )

  log(
    "driver",
    f"drive_skill done: turns={run.turns} yes_replies={run.yes_replies} "
    f"lines={run.events_received} exit_code={run.exit_code} "
    f"completed={run.completed} timed_out={run.timed_out} "
    f"elapsed={time.time() - loop_start:.1f}s",
  )

  if transcript_path is not None:
    run.save_transcript(transcript_path)
    log("driver", f"transcript written to {transcript_path}")

  return run


def _run_one_turn(
  workspace: Path,
  prompt: str,
  *,
  per_turn_timeout: float,
  use_continue: bool,
) -> tuple[list[str], int | None, str, bool]:
  """Spawn one `copilot` invocation and return (stdout_lines, exit_code,
  stderr_tail, timed_out).

  Each call is a fresh subprocess — Copilot CLI is single-shot per
  invocation. `use_continue=True` adds `--continue` so the process
  resumes the previous session's conversation history instead of
  starting fresh.
  """
  cmd = ["copilot"]
  if use_continue:
    # -C pins the resumed session's working directory to our workspace.
    # Without it, --continue's "resume in saved cwd" default applies and
    # can land in whatever dir the original session was spawned from.
    cmd.extend(["--continue", "-C", str(workspace)])
  cmd.extend([
    "-p", prompt,
    "-s",
    "--allow-all-tools",
    "--no-ask-user",
    "--add-dir", str(workspace),
  ])
  model = os.environ.get("COPILOT_MODEL")
  if model:
    cmd.extend(["--model", model])

  log("driver", f"spawn: {' '.join(cmd[:3])} ... (--continue={use_continue})")
  log("driver", f"prompt: {_brief(prompt, 200)}")
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

  stdout_lines: list[str] = []
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
          f"TIMEOUT after {per_turn_timeout}s waiting for next stdout line "
          f"(lines this turn: {len(stdout_lines)}, "
          f"elapsed: {time.time() - turn_start:.1f}s)",
        )
        break

      if line is None:
        log(
          "driver",
          f"stdout EOF (copilot exited); lines this turn: {len(stdout_lines)}",
        )
        break

      stdout_lines.append(line)
      if line.strip():
        log("driver", f"stdout #{len(stdout_lines)}: {_brief(line, 200)}")
  finally:
    try:
      proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
      log("driver", "copilot did not exit within 15s; killing")
      proc.kill()
      proc.wait(timeout=5)

  stderr_tail = "\n".join(err_lines[-40:])
  log(
    "driver",
    f"turn done: exit={proc.returncode} lines={len(stdout_lines)} "
    f"timed_out={timed_out} elapsed={time.time() - turn_start:.1f}s",
  )
  return stdout_lines, proc.returncode, stderr_tail, timed_out


def _log_startup(
  workspace: Path,
  initial_prompt: str,
  per_turn_timeout: float,
  max_turns: int,
) -> None:
  log("driver", f"drive_skill called: workspace={workspace}")
  log("driver", f"initial_prompt: {_brief(initial_prompt, 200)}")
  log(
    "driver",
    f"per_turn_timeout={per_turn_timeout}s max_turns={max_turns}",
  )

  copilot_path = shutil.which("copilot")
  log("driver", f"copilot on PATH: {copilot_path}")
  if copilot_path:
    try:
      out = subprocess.run(
        ["copilot", "--version"],
        capture_output=True, text=True, timeout=10,
      )
      log("driver", f"copilot --version: {(out.stdout or out.stderr).strip()}")
    except Exception as e:
      log("driver", f"copilot --version failed: {e}")

  for key in ECHOED_ENV_KEYS:
    log("driver", f"env {key}={os.environ.get(key, '(unset)')}")
  for key in SECRET_ENV_KEYS:
    val = os.environ.get(key)
    if val:
      log("driver", f"env {key}=set (length={len(val)}, ...{val[-4:]})")
    else:
      log("driver", f"env {key}=MISSING")


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
