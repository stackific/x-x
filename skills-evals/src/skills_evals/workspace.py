# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Read an eval workspace and render it as plain text for an LLM judge.

The workspace is whatever directory `stax init` was run in followed by a
planner/executor loop. Two categories of paths get excluded from what the
judge sees:

  - Scaffold dirs (`.stax/`, `.claude/`, …) — installed by `stax init`
    before the agent runs; not the agent's deliverable.
  - Noise dirs (`node_modules/`, `.venv/`, `__pycache__/`, build outputs,
    …) — the agent may legitimately create these as a side effect (e.g.
    running `npm install jsdom` to smoke-test the HTML it just wrote per
    /ship's verify-before-flip rule). Vendored deps and build caches
    aren't the agent's deliverable either, and they routinely blow the
    judge's context budget (one prior CI run dumped 11 MB of
    node_modules and got rejected with a 400 from DeepSeek's 1M-token cap).

A total-bytes backstop bounds the combined dump regardless of file
count: if a future surprise dir blows past the cap, the dump is
truncated with an explicit marker the judge can see.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

# Installed by `stax init` before the planner/executor runs.
SCAFFOLD_DIRS = {".stax", ".claude", ".agents", ".git", ".codex"}

# Dirs the agent may create as a side effect (vendored deps, virtualenvs,
# build outputs, caches). Not scaffold, but not the deliverable either.
NOISE_DIRS = {
  "node_modules",
  ".venv", "venv",
  "__pycache__",
  "dist", "build", "target",
  ".next", ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache",
}

# Combined exclusion set. Used as a path-component blacklist — a path is
# excluded if ANY of its components match (handles nested cases like
# `pkg/node_modules/foo`).
EXCLUDED_DIRS = SCAFFOLD_DIRS | NOISE_DIRS

# Per-file cap. The judge prompt grows linearly with artifact size;
# truncating per-file stops a misbehaving executor from blowing the prompt
# budget on a single large file.
MAX_FILE_BYTES = 32_000

# Total combined cap on the produced-files dump. DeepSeek's pro model has
# a 1M-token (~4 MB) context window; we keep the artifact section well
# under that to leave room for the rubric prompt and the tree summary.
# When the cap fires, a truncation marker is appended so the judge can
# see that the input was bounded (and not score it as "agent produced
# nothing").
MAX_TOTAL_ARTIFACT_BYTES = 500_000


def _is_excluded(rel: Path) -> bool:
  """True if any path component is in EXCLUDED_DIRS."""
  return any(part in EXCLUDED_DIRS for part in rel.parts)


def collect_plan_files(workspace: Path) -> str:
  """Concatenated text of every <prefix>-<slug>.md under .stax/.

  Underscore-prefixed registry files (_data_systems.yaml, _config.lock)
  are skipped — they're scaffold, not scopes.
  """
  plans_dir = workspace / ".stax"
  if not plans_dir.is_dir():
    return "(no .stax/ directory)"
  chunks = []
  for p in sorted(plans_dir.glob("*.md")):
    if p.name.startswith("_"):
      continue
    chunks.append(_dump_file(p, workspace))
  return "\n".join(chunks) if chunks else "(no scope files)"


def collect_produced_files(workspace: Path) -> str:
  """Concatenated text of every produced file, scaffold + noise excluded.

  Stops dumping once the combined size hits MAX_TOTAL_ARTIFACT_BYTES and
  appends an explicit truncation marker so the judge sees a bounded
  input rather than silently losing tail files.
  """
  chunks: list[str] = []
  total = 0
  for p in sorted(workspace.rglob("*")):
    if not p.is_file():
      continue
    try:
      rel = p.relative_to(workspace)
    except ValueError:
      continue
    if _is_excluded(rel):
      continue
    chunk = _dump_file(p, workspace)
    if total + len(chunk) > MAX_TOTAL_ARTIFACT_BYTES:
      chunks.append(
        f"\n... [total artifact size cap of {MAX_TOTAL_ARTIFACT_BYTES} "
        f"bytes reached; remaining files elided]\n"
      )
      break
    chunks.append(chunk)
    total += len(chunk)
  return "\n".join(chunks) if chunks else "(no produced files)"


def collect_tree(workspace: Path) -> str:
  """One line per file/dir; excluded top-level dirs are collapsed.

  `.stax/` is the one scaffold dir whose contents stay visible — the
  judge needs to see scope filenames in the tree. Everything else in
  SCAFFOLD_DIRS or NOISE_DIRS is shown as a single collapsed line at
  its top level; nested matches (e.g. `pkg/node_modules/foo`) are
  dropped silently to keep the tree readable.
  """
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
    if top in EXCLUDED_DIRS and top != ".stax":
      if top in seen_collapsed:
        continue
      seen_collapsed.add(top)
      kind = "scaffold" if top in SCAFFOLD_DIRS else "noise"
      lines.append(f"[d] {top}/  ({kind}, contents elided)")
      continue
    # Drop deeper nested noise (e.g. `pkg/node_modules/foo`) without a
    # collapse label — keeps the tree readable for legitimate files.
    if _is_excluded(rel):
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
  """A scope file with its YAML frontmatter parsed.

  Tests assert on relationship fields (`status`, `supersedes`,
  `superseded_by`, `extends`, `extended_by`) directly — deterministic
  Python parsing is the right tool, not LLM judgment.
  """

  path: Path
  slug: str  # filename stem, e.g. "0001-build-todo-app"
  frontmatter: dict = field(default_factory=dict)
  body: str = ""


def load_all_scopes(workspace: Path) -> list[ParsedPlan]:
  """Parse every <prefix>-<slug>.md under .stax/, sorted by filename.

  Underscore-prefixed registry files (_data_systems.yaml, _config.lock)
  are skipped — they're scaffold, not scopes. A file that doesn't open
  with a `---` frontmatter block is skipped; the caller can assert
  `len(scopes) == N` to catch a malformed result.
  """
  plans_dir = workspace / ".stax"
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
