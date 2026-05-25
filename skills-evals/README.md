# skills-evals

LLM-judged evaluations for the `x-x` planner (`/x-plan`) + executor (`/x-x`)
loop. Managed with [uv](https://docs.astral.sh/uv/) and built on
[DeepEval](https://github.com/confident-ai/deepeval).

## Layout

```
skills-evals/
├── pyproject.toml              # uv project (deepeval, openai)
├── scenarios/                  # <agent>-<name>.md scenarios with `task:` frontmatter
└── src/skills_evals/
    ├── cli.py                  # entrypoint: skills-evals --scenario ... --workspace ...
    ├── scenarios.py            # frontmatter parser
    ├── workspace.py            # collects artifacts from an eval workspace
    ├── models.py               # DeepSeek wrapper for DeepEval
    └── judges/
        ├── base.py             # Judge ABC + Judgment dataclass
        └── rubric.py           # 4-criterion rubric via DeepEval GEval
```

## Run locally

```sh
cd skills-evals
uv sync
export DEEPSEEK_API_KEY=sk-...
uv run skills-evals \
  --scenario scenarios/claude-deepseek-baseline.md \
  --workspace /path/to/eval-workspace \
  --output judgment.json
```

Exit code is `0` if every judge passed, `1` if any failed, `2` on a usage
or setup error.

## Run in CI

`.github/workflows/exp-claude-deepseek-judge.yml` drives a full end-to-end
loop: install `x-x`, init a throwaway workspace, run `/x-plan` then `/x-x`
through Claude Code on DeepSeek, then call this runner.

## Adding a judge

1. Create `src/skills_evals/judges/<name>.py` with a `Judge` subclass that
   sets a `name` class attribute and implements
   `evaluate(self, task: str, workspace: Path) -> Judgment`.
2. Register it in `src/skills_evals/judges/__init__.py` (add to `JUDGES`).
3. Run it on its own with `--judge <name>`, or omit `--judge` to run all.

A judge evaluates _what is being checked_ (rubric correctness, security,
accessibility, …); the agent that produced the artifacts (claude, codex,
cursor) is captured in the scenario filename, not the judge name.

## Adding a scenario

Drop `scenarios/<agent>-<name>.md` with the frontmatter:

```markdown
---
task: One-line task string handed to /x-plan.
---

# Notes (free-form)
```

Then trigger the workflow with `scenario: <agent>-<name>`.
