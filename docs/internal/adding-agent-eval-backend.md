# Adding a new agent backend to skills-evals

This guide walks the next contributor through integrating a new agent
backend (Cursor, Gemini CLI, GitHub Copilot CLI, OpenAI Codex, etc.)
into the existing `skills-evals` test suite alongside the Claude path.

The Claude implementation is the reference. Read
`skills-evals/src/skills_evals/claude_driver.py` and
`.github/workflows/skills-eval-claude.yml` before starting — every
section below maps to something already shipped there.

## Current state

- One agent backend routed: Claude Code, routed at DeepSeek's
  Anthropic-compatible endpoint.
- Two scope workflows: `skills-eval-claude.yml` (project scope) and
  `skills-eval-claude-user-scope.yml` (user scope). They share the
  same pytest scenarios and differ only in the `STAX_INSTALL_SCOPE`
  env var.
- Four pytest scenarios under `skills-evals/tests/` per agent. The
  filename pattern is `test_<agent>_<scenario>.py`; the conftest's
  `pytest_collection_modifyitems` reads `STAX_AGENT_KEY` (default
  `claude`) and deselects every file that doesn't match the active
  agent, so a session runs exactly one backend's collection without
  cross-contamination. Claude's set today:
  - `test_claude_stream_json_smoke.py` — shape-check on the wire (runs first)
  - `test_claude_plan_extends.py` — bidirectional `extends:` /
    `extended_by:` link mechanic, planner only
  - `test_claude_reminders_supersedes_todo.py` — full e2e with
    supersedes mechanic + artifact verification
  - `test_claude_todo.py` — original single-work-item baseline
  OpenCode ships the same four scenarios under `test_opencode_*.py`.
- Two DeepEval `GEval` judges backed by DeepSeek-flash:
  `WorkItemJudge` (work-item-file validity) and `ArtifactJudge` (produced
  artifact correctness).

## Architecture: shared vs agent-specific

### Shared infrastructure (reuse as-is)

| File | Why agent-agnostic |
|---|---|
| `skills_evals/judges/{work_item,artifact}_judge.py` | Score work-item/artifact files against rubrics; don't care which agent produced them. |
| `skills_evals/models.py` | DeepSeek wrapper for the judge LLM. Same judge model regardless of the agent under test. |
| `skills_evals/workspace.py` | `collect_plan_files` / `collect_produced_files` / `collect_tree` / `load_all_plans` — read the filesystem; agent-agnostic. Includes the noise/scaffold exclusion + size-cap logic. |
| `skills_evals/_logging.py` | Timestamped stderr logger. |
| `tests/conftest.py` `workspace` fixture | `stax init` runs the same way for any agent (just pass a different `--agents` value). |

### Agent-specific (clone + adapt)

| File | What changes |
|---|---|
| `skills_evals/<agent>_driver.py` | Subprocess spawn, protocol parsing, auto-yes loop. Each agent's CLI has different conventions; cannot be fully abstracted today. |
| `tests/conftest.py` env defaults | Routing env vars are agent-specific (Claude uses `ANTHROPIC_*`; Cursor will use `CURSOR_*`; Gemini uses `GOOGLE_*`; …). Add a new defaults dict per agent. |
| `tests/test_<agent>_*.py` | Either duplicate the test files (per-agent driver import) or refactor to a shared file with a `driver` fixture. Start with duplication; refactor once you have ≥3 backends. |
| `.github/workflows/skills-eval-<agent>.yml` | Install step (npm/pip/cargo/bash), env block, secret mapping. |

## Step-by-step recipe

### 1. Vet the agent's CLI

Before writing any code, confirm the agent's CLI supports headless
multi-turn operation. For each backend, find and document:

- **Install command** (npm? pip? cargo? bash installer? brew?)
- **Headless invocation flag** (Claude: `-p`; expect each agent to
  differ)
- **Stream / event format** (JSON Lines? raw text? proprietary
  protocol?)
- **Multi-turn support** — does the process stay alive between user
  messages, or does each turn require a new invocation with
  `--resume <session-id>` or equivalent?
- **Permission-prompt bypass** — Claude has
  `--dangerously-skip-permissions`; find the equivalent
- **Environment variable for the model endpoint** — needed to route
  the agent at DeepSeek (or whatever LLM you're testing against)

Capture all of this in a comment at the top of the new driver module.
If the agent doesn't support a single piece of that list, stop and
discuss with the user — there may be a fundamentally different
integration path needed.

### 2. Implement `<agent>_driver.py`

Mirror the public surface of `claude_driver.py`:

```python
def drive_skill(
  workspace: Path,
  initial_prompt: str,
  *,
  max_turns: int = DEFAULT_MAX_TURNS,
  per_turn_timeout: float = DEFAULT_PER_TURN_TIMEOUT_S,
  transcript_path: Path | None = None,
) -> SkillRun:
  ...
```

Reuse `SkillRun` and `_logging.log` from the shared modules. The
internal implementation is whatever the agent's CLI needs:

- Subprocess spawn with the agent's headless flags
- Stream reader that parses the agent's protocol format and pushes events
  through a queue (the Claude pattern uses two daemon threads — one
  for stdout, one for stderr — to avoid pipe-buffer deadlocks)
- Auto-yes loop: detect end-of-turn, check the agent's final text for
  a confirmation prompt (`reply\s+yes` is the protocol phrase in the
  shipped skills), write `yes` as the next user message, continue
  reading

**Logging policy (non-negotiable):** every event the agent emits gets
a one-line log entry with type + key fields. Every state transition
in the driver logs a line. Stderr from the agent streams live, not
buffered. CI logs are the only post-mortem surface — silence is a bug.

### 3. Route the conftest

Add a defaults dict for the new agent's env vars next to
`CLAUDE_ENV_DEFAULTS`:

```python
CURSOR_ENV_DEFAULTS = {
  "CURSOR_MODEL": "deepseek-v4-pro[1m]",
  "CURSOR_BASE_URL": "https://api.deepseek.com/...",
  # ...
}
```

If the agent picks its routing via different env vars from
`DEEPSEEK_API_KEY`, mirror the secret into the right name in the
session fixture (Claude does this:
`os.environ["ANTHROPIC_AUTH_TOKEN"] = api_key`).

The `workspace` fixture already runs `stax init`. Update its
`--agents` flag if the new agent isn't in the existing list. Set
`STAX_INSTALL_SCOPE` via env if you want a user-scope variant
workflow.

### 4. Adapt the test scenarios

Two options:

- **Per-agent test files** (e.g., `test_cursor_todo.py` that imports
  `cursor_driver.drive_skill`). Duplicates more; easier to maintain
  when one backend's tests need to diverge from another's. Start here
  for the first 1-2 backends.
- **Single shared test file with a `driver` fixture** that picks the
  right backend based on an env var or pytest mark. Less duplication
  but adds a layer. Refactor to this once you have ≥3 backends and
  the duplication actually hurts.

The `TASK` strings (prompts to the agent) and assertions are
agent-agnostic. They test the AGENT'S behavior against the skill
spec — not the protocol format.

### 5. Add the workflow file

Copy an existing one as a starting point:

```sh
cp .github/workflows/skills-eval-claude.yml \
   .github/workflows/skills-eval-<agent>.yml
```

Update:

- `name:` — human-readable label shown in the Actions UI
- Install step — `npm install -g cursor`, `pip install gemini-cli`,
  etc. Pin to a known-good version once you have one
  (`@latest` is fragile when the agent's protocol format evolves)
- `env:` block — agent-specific routing vars + secret mapping
- `actions/*` versions — match the existing workflow's pins
- Concurrency / caching — keep `setup-uv` cache enabled; the uv
  install hits the same lockfile regardless of agent

### 6. First CI run

GitHub Actions UI registers workflows from the **default branch
only.** A new workflow file on a feature branch can't be triggered
from the UI or `gh workflow run` until it lands on `main`. Two
working paths:

- Merge the workflow file to `main` first (small focused PR), then
  trigger from the Actions tab on your feature branch
- Add the workflow + the rest of the changes in one PR, merge when
  the local pytest suite (`uv run pytest`) passes

Once triggered, watch the verbose log:

- Every event the agent emits should appear on stderr
- The auto-yes loop should fire when the agent ends a turn with
  `reply yes` (or your agent's equivalent confirmation phrase)
- Both judges should pass against threshold 0.7

If the run fails, the failure is almost always one of:

- **Protocol-format mismatch** — driver parses for the wrong event format.
  Fix: log every event type + key fields and see what the agent
  actually emits.
- **Auto-yes never fires** — the end-of-turn signal you keyed off
  isn't what the agent uses on this LLM backend. Fix: read the
  transcript, find the boundary that matters, key off that.
- **Judge context overflow** — the artifact dump exceeds the model's
  context window. Fix: extend `NOISE_DIRS` in `workspace.py` to
  cover whatever agent-installed bloat your run produced
  (`node_modules`, `.venv`, `target`, …). The 500 KB total-bytes
  backstop will save you from new bloat dirs you haven't named yet.

## Per-agent gotchas (observed)

### Claude Code on DeepSeek

- `--input-format stream-json` is undocumented
  ([anthropics/claude-code#24594](https://github.com/anthropics/claude-code/issues/24594)).
  Protocol format reverse-engineered from community sources.
- DeepSeek's Anthropic-compat shim strips `stop_reason` from
  assistant events. Per-turn end-signal is the `result` event, NOT
  `assistant.stop_reason == "end_turn"`.
- `--output-format stream-json` requires `--verbose` on recent
  versions or the CLI errors out / emits nothing.
- Claude stays alive after a `result` event and accepts the next
  user message on the same stdin — multi-turn streaming works
  without `--resume`.

### Cursor / Gemini / Codex / Copilot

Document quirks here as each backend ships. Things to record:

- Exact CLI install command and pinned version
- Headless invocation flags
- Stream format (or lack thereof)
- Whether the process stays alive between turns
- How permission/auth bypass works in CI
- The end-of-turn detection signal

## Anti-patterns

These have all bitten this repo at some point — don't repeat them.

### Don't lower judge thresholds to make a test pass

The judges score against an objective rubric. If they're scoring
artifacts low, the artifact is bad (real signal) or the rubric needs
sharpening (improve the criteria, don't lower the bar).

### Don't bypass the auto-yes loop with prescriptive prompts

Telling the agent "Add `supersedes: [<slug>]` to your work item
frontmatter" bypasses the planner's natural workflow. Tests should
validate the agent's natural behavior, not script it.

### Don't include vendored deps in the artifact dump

When the agent runs `npm install` or `pip install` for verification
(per `agents/skills/ship/SKILL.md:64`), `node_modules/` / `.venv/`
appear in the workspace. The judge shouldn't see vendored code as
the agent's "deliverable". `workspace.py`'s `NOISE_DIRS` already
covers the common ones; add new entries as you discover bloat from
the new backend.

### Don't silently fall back when the protocol format mismatches

A driver that "works" on bad input by returning empty data is
unfixable. Log loudly, fail explicitly with a clear message.

### Don't hard-code the worktree path

This repo uses sibling worktrees under `.worktrees/<branch-name>/`.
Always anchor with `pwd && git rev-parse --show-toplevel` before
writing files. Absolute paths like
`/Users/t/work/github/stackific/stax/...` are wrong — they target the
main worktree, not the branch you're editing.

## Cost and time expectations

- Per scenario (planner + executor + 1-2 judge LLM calls):
  ~$0.30-$1.50 in DeepSeek spend, 3-10 minutes wall clock.
- Per workflow run (4 scenarios today): ~$4, ~15 minutes.
- Per agent backend, multiplied by however many workflows you add
  (project scope + user scope = 2 workflows per agent).
- Add a 60-minute job timeout in the workflow as a backstop against
  a stuck agent.

## DCO and commit hygiene

- Every commit MUST end with `Signed-off-by: <Real Name> <email>`
  matching `git config user.email`. Pass `-s` to every
  `git commit`.
- Commit messages MUST NOT contain `Co-Authored-By:` trailers or
  any AI/agent attribution (per `CLAUDE.md`). This is a hard
  merge-blocking constraint.
- Conventional-commit subject types accepted by the project's
  conform check: `feat fix docs style refactor perf test build ci
  chore revert`.

## References

- `agents/skills/scope/SKILL.md` — what the planner skill expects
  from the agent; Appendix A inside that file documents the
  bidirectional work-item-link contract (extends/supersedes)
- `agents/skills/ship/SKILL.md` — what the executor skill expects
  (review modes, verify-before-flip, etc.)
- `skills-evals/README.md` — local dev setup
- `docs/internal/manually-triggered-workflows.md` — workflow
  conventions and DeepSeek routing
- `docs/internal/commit-signing.md` — signing convention
