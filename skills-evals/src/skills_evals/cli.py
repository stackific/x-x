# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Command-line entrypoint.

Run one or more judges against an eval workspace and exit 0/1 based on the
aggregate pass.

Examples:
  skills-evals --scenario scenarios/claude-deepseek-baseline.md \\
               --workspace /tmp/eval-workspace
  skills-evals --task "Build a TODO app" --workspace . --judge rubric
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .judges import JUDGES
from .scenarios import load_scenario


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
  ap = argparse.ArgumentParser(prog="skills-evals", description=__doc__)
  ap.add_argument(
    "--scenario",
    help="path to a scenario .md file; the task is read from its frontmatter",
  )
  ap.add_argument(
    "--task",
    help="task string (overrides --scenario's task if both are given)",
  )
  ap.add_argument(
    "--workspace",
    required=True,
    type=Path,
    help="workspace directory the planner+executor wrote into",
  )
  ap.add_argument(
    "--judge",
    action="append",
    default=None,
    help=(
      f"judge to run; may be repeated. "
      f"default: all registered ({', '.join(JUDGES)})"
    ),
  )
  ap.add_argument(
    "--output",
    type=Path,
    default=Path("judgment.json"),
    help="where to write the aggregate judgment JSON",
  )
  return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
  args = _parse_args(argv)

  if args.task:
    task = args.task
  elif args.scenario:
    task = load_scenario(args.scenario).task
  else:
    print("--task or --scenario required", file=sys.stderr)
    return 2

  if not args.workspace.is_dir():
    print(f"workspace is not a directory: {args.workspace}", file=sys.stderr)
    return 2

  selected = args.judge or list(JUDGES.keys())
  for name in selected:
    if name not in JUDGES:
      print(
        f"unknown judge: {name} (available: {', '.join(JUDGES)})",
        file=sys.stderr,
      )
      return 2

  judgments = []
  overall_pass = True
  for name in selected:
    judge = JUDGES[name]()
    result = judge.evaluate(task, args.workspace)
    judgments.append(result.to_dict())
    overall_pass = overall_pass and result.passed

  output = {
    "pass": overall_pass,
    "task": task,
    "judgments": judgments,
  }
  args.output.write_text(json.dumps(output, indent=2))
  print(json.dumps(output, indent=2))
  return 0 if overall_pass else 1


if __name__ == "__main__":
  sys.exit(main())
