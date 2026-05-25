# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Parse scenario markdown files.

Scenarios live under skills-evals/scenarios/<agent>-<name>.md and carry a
YAML frontmatter block. Today only `task:` is required; future keys
(model overrides, judge-specific config) parse into Scenario.frontmatter
without code changes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Scenario:
  name: str
  task: str
  body: str
  frontmatter: dict = field(default_factory=dict)


def load_scenario(path: str | Path) -> Scenario:
  p = Path(path)
  if not p.is_file() and p.suffix != ".md":
    candidate = p.with_suffix(".md")
    if candidate.is_file():
      p = candidate
  if not p.is_file():
    raise FileNotFoundError(f"scenario not found: {path}")
  frontmatter, body = _split_frontmatter(p.read_text(encoding="utf-8"))
  task = frontmatter.get("task")
  if not task:
    raise ValueError(f"scenario {p} has no `task:` in frontmatter")
  return Scenario(name=p.stem, task=task, body=body, frontmatter=frontmatter)


def _split_frontmatter(text: str) -> tuple[dict, str]:
  lines = text.splitlines()
  if not lines or lines[0].strip() != "---":
    return {}, text
  frontmatter: dict = {}
  body_start = len(lines)
  for i in range(1, len(lines)):
    if lines[i].strip() == "---":
      body_start = i + 1
      break
    if ":" in lines[i]:
      key, _, value = lines[i].partition(":")
      frontmatter[key.strip()] = value.strip()
  body = "\n".join(lines[body_start:])
  return frontmatter, body
