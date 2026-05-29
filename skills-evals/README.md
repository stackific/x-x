# skills-evals

End-to-end evaluations of the `stax` planner (`/scope`) + executor (`/ship`)
skills against Claude Code. Each test:

1. Spawns `claude` in stream-json mode against DeepSeek.
2. Invokes `/scope <task>` and auto-replies `yes` to every confirmation
   prompt until the planner stops asking.
3. Scores the produced scope file with a DeepEval `GEval` judge.
4. Invokes `/ship`, auto-replies `yes` until the executor stops asking.
5. Scores the produced artifacts with a second `GEval` judge.

Managed with [uv](https://docs.astral.sh/uv/) and built on
[DeepEval](https://github.com/confident-ai/deepeval).

## Layout

```
skills-evals/
├── pyproject.toml                       # uv project (deepeval, openai, python-dotenv, pytest)
├── src/skills_evals/
│   ├── claude_driver.py                 # stream-json subprocess + auto-yes loop
│   ├── workspace.py                     # collects scope/produced artifacts as text
│   ├── models.py                        # DeepSeek wrapper for DeepEval
│   └── judges/
│       ├── base.py                      # Judge ABC + Judgment dataclass
│       ├── scope_judge.py                # GEval on the scope file
│       └── artifact_judge.py            # GEval on /ship's produced files
└── tests/
    ├── conftest.py                      # .env load + DeepSeek/Anthropic routing + workspace fixture
    └── test_claude_todo.py              # the TODO-app scenario
```

## Prerequisites

- `stax` on PATH (`go install .` from repo root).
- `claude` on PATH (`npm install -g @anthropic-ai/claude-code`).
- A DeepSeek API key. Put it in `skills-evals/.env`:
  ```
  DEEPSEEK_API_KEY=sk-...
  ```
  The fixture loads `.env` and uses the same key for the judge LLM
  (DeepSeek direct) and the Claude Code backend (DeepSeek via
  `ANTHROPIC_*` env vars).

## Run

```sh
cd skills-evals
uv sync
uv run pytest
```

A single test runs an entire planner + executor loop on a real Claude
session against DeepSeek — expect 5–15 minutes per scenario and real API
spend. Output is verbose (`-v -s` in `pyproject.toml`) so you can watch
the driver narrate the auto-yes loop and the judges report their scores.

## Stream-json + auto-yes

`claude_driver.py` spawns `claude -p --input-format stream-json
--output-format stream-json --dangerously-skip-permissions` once per
skill. It reads JSON-Lines events on stdout, accumulates each turn's
assistant text, and when the agent ends a turn it checks whether the
text ends on the protocol phrase `Reply yes to proceed`. If yes, it
writes `{"type":"user","message":{"role":"user","content":"yes"}}` to
stdin and loops. If no, the agent is done — the driver closes stdin and
returns. A `max_turns=20` cap keeps a misbehaving agent from running
forever.

## Adding a scenario

Drop another `tests/test_<agent>_<name>.py` mirroring `test_claude_todo.py`:
hardcode the task, call `drive_skill(workspace, "/scope <task>")`,
assert `ScopeJudge`, call `drive_skill(workspace, "/ship")`, assert
`ArtifactJudge`. The `workspace` fixture already initializes a throwaway
project. New backends get their own driver — the
DeepEval judges are agent-agnostic and can be reused as-is.
