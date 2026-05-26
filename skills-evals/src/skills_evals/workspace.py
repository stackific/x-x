# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Read an eval workspace and render it as plain text for an LLM judge.

The workspace is whatever directory `x-x init` was run in followed by a
planner/executor loop. Scaffold directories (`.x-plans/`, `.claude/`, ...)
are installed by `x-x init` itself and so are not "produced artifacts" —
they're collapsed in the tree summary and skipped in the per-file dump.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

# Installed by `x-x init` before the planner/executor runs. The judge sees
# them in the tree summary but the per-file dump skips them so the prompt
# stays bounded.
SCAFFOLD_DIRS = {".x-plans", ".claude", ".agents", ".git", ".codex", ".x-x"}

# Per-file cap. The judge prompt grows linearly with artifact size;
# truncating per-file stops a misbehaving executor from blowing the prompt
# budget on a single large file.
MAX_FILE_BYTES = 32_000


def collect_plan_files(workspace: Path) -> str:
  """Concatenated text of every <prefix>-<slug>.md under .x-plans/.

  Underscore-prefixed registry files (_data_systems.yaml, _config.lock)
  are skipped — they're scaffold, not plans.
  """
  plans_dir = workspace / ".x-plans"
  if not plans_dir.is_dir():
    return "(no .x-plans/ directory)"
  chunks = []
  for p in sorted(plans_dir.glob("*.md")):
    if p.name.startswith("_"):
      continue
    chunks.append(_dump_file(p, workspace))
  return "\n".join(chunks) if chunks else "(no plan files)"


def collect_produced_files(workspace: Path) -> str:
  """Concatenated text of every file in the workspace minus scaffold dirs."""
  chunks = []
  for p in sorted(workspace.rglob("*")):
    if not p.is_file():
      continue
    try:
      rel = p.relative_to(workspace)
    except ValueError:
      continue
    if rel.parts and rel.parts[0] in SCAFFOLD_DIRS:
      continue
    chunks.append(_dump_file(p, workspace))
  return "\n".join(chunks) if chunks else "(no produced files)"


def collect_tree(workspace: Path) -> str:
  """One line per file/dir; scaffold dirs shown as collapsed entries."""
  lines = []
  seen_collapsed: set[str] = set()
  for p in sorted(workspace.rglob("*")):
    try:
      rel = p.relative_to(workspace)
    except ValueError:
      continue
    if not rel.parts:
      continue
    top = rel.parts[0]
    if top in SCAFFOLD_DIRS and top != ".x-plans":
      if top in seen_collapsed:
        continue
      seen_collapsed.add(top)
      lines.append(f"[d] {top}/  (scaffold, contents elided)")
      continue
    prefix = "[d] " if p.is_dir() else "    "
    lines.append(f"{prefix}{rel}")
  return "\n".join(lines) if lines else "(empty workspace)"


def _dump_file(p: Path, workspace: Path) -> str:
  try:
    content = p.read_text(encoding="utf-8", errors="replace")
  except OSError as e:
    return f"--- {p.relative_to(workspace)} (read error: {e}) ---\n"
  if len(content) > MAX_FILE_BYTES:
    content = content[:MAX_FILE_BYTES] + "\n... [truncated]"
  return f"--- {p.relative_to(workspace)} ---\n{content}\n"


@dataclass
class ParsedPlan:
  """A plan file with its YAML frontmatter parsed.

  Tests assert on relationship fields (`status`, `supersedes`,
  `superseded_by`, `extends`, `extended_by`) directly — deterministic
  Python parsing is the right tool, not LLM judgment.
  """

  path: Path
  slug: str  # filename stem, e.g. "0001-build-todo-app"
  frontmatter: dict = field(default_factory=dict)
  body: str = ""


def load_all_plans(workspace: Path) -> list[ParsedPlan]:
  """Parse every <prefix>-<slug>.md under .x-plans/, sorted by filename.

  Underscore-prefixed registry files (_data_systems.yaml, _config.lock)
  are skipped — they're scaffold, not plans. A file that doesn't open
  with a `---` frontmatter block is skipped; the caller can assert
  `len(plans) == N` to catch a malformed result.
  """
  plans_dir = workspace / ".x-plans"
  if not plans_dir.is_dir():
    return []
  out: list[ParsedPlan] = []
  for p in sorted(plans_dir.glob("*.md")):
    if p.name.startswith("_"):
      continue
    parsed = _parse_plan(p)
    if parsed is not None:
      out.append(parsed)
  return out


def _parse_plan(p: Path) -> ParsedPlan | None:
  text = p.read_text(encoding="utf-8", errors="replace")
  if not text.startswith("---\n"):
    return None
  end_marker = "\n---\n"
  end = text.find(end_marker, 4)
  if end == -1:
    return None
  fm_text = text[4:end]
  body = text[end + len(end_marker):]
  try:
    fm = yaml.safe_load(fm_text) or {}
  except yaml.YAMLError:
    fm = {}
  if not isinstance(fm, dict):
    fm = {}
  return ParsedPlan(path=p, slug=p.stem, frontmatter=fm, body=body)
