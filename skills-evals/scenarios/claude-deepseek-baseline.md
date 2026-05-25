---
task: Build a single-page HTML client-side TODO list app with localStorage persistence.
---

# Baseline scenario

This scenario asks the planner (`/x-plan`) and executor (`/x-x`) to produce a
small, self-contained client-side web app. It's representative of what end
users would invoke the skills for: a single project that uses no external
services and can be verified by opening one file in a browser.

## What success looks like

The artifact should be a single HTML file (no external CDN, no backend, no
build step) that:

- Provides a text input and an "add" button to create TODO items.
- Renders the current list of TODOs.
- Lets the user mark an item done and delete an item.
- Persists the list across page reloads via `localStorage`.

## Judge

The `rubric` judge (`skills-evals/src/skills_evals/judges/rubric.py`) scores
the artifacts on four criteria — plan file validity, presence of produced
artifacts, task satisfaction, and syntactic well-formedness. It is wired
through DeepEval's `GEval` metric and runs against DeepSeek (see
`skills-evals/README.md`).

## Adding more scenarios

Drop another `skills-evals/scenarios/<agent>-<scenario>.md` file with the
same `task:` frontmatter shape. The `<agent>-` prefix keeps Claude/Codex/
Cursor scenarios from colliding once we add more agent backends. Trigger
the workflow with `scenario: <agent>-<scenario>` from the Actions tab.
