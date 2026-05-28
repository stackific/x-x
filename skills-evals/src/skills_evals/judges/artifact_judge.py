# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""DeepEval judge that scores the artifacts produced by /ship.

Runs after /ship finishes. Looks at every file in the workspace EXCEPT the
scaffold directories (.stax/, .claude/, .agents/, .git/, .codex/,
.stax/) — those were written by `stax init` and the planner, not by the
executor. The judge asks: did /ship produce real artifacts that satisfy
the task?
"""

from __future__ import annotations

import time
from pathlib import Path

from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

from .._logging import log
from ..models import DEFAULT_JUDGE_MODEL, DeepSeekModel
from ..workspace import collect_produced_files, collect_tree
from .base import Judge, Judgment

INPUT_TEMPLATE = """\
The user asked a ship executor agent to:

{task}

The executor's job was to produce concrete artifacts in the workspace
that satisfy the task. The actual output below dumps every produced file
(scaffold directories like .stax/, .claude/, .agents/ are excluded)
and then a tree summary of the workspace for context.
"""

ARTIFACT_TEMPLATE = """\
=== Produced files (scaffold directories excluded) ===

{produced_files}

=== Workspace tree (scaffold dirs collapsed) ===

{tree}
"""

EVALUATION_STEPS = [
  (
    "Verify the produced files section contains at least one concrete "
    "artifact — a real file the executor wrote that wasn't already part of "
    "the init scaffold. An empty 'Produced files' section is an automatic "
    "fail; the executor did nothing."
  ),
  (
    "Verify the produced artifacts implement the task in the input as "
    "literally stated. If the task names a specific technology or behavior "
    "(e.g. 'single HTML file', 'localStorage persistence', 'client-side "
    "only'), the artifacts must demonstrate that — file extensions, code "
    "patterns, and visible logic must match."
  ),
  (
    "Verify each produced file is syntactically well-formed for its file "
    "type (HTML parses, JS has balanced braces and no obvious errors, "
    "Python is valid, etc., based on what is visible in the dump). "
    "Truncated files are acceptable — judge what you can see."
  ),
  (
    "Verify the artifact set is self-contained relative to what the task "
    "asks for. If the task says 'no external services' or 'client-side', "
    "reject artifacts that import a backend SDK, hit a network endpoint, "
    "or assume server-side rendering."
  ),
]


class ArtifactJudge(Judge):
  name = "artifact"

  def __init__(
    self,
    model_name: str = DEFAULT_JUDGE_MODEL,
    threshold: float = 0.7,
  ) -> None:
    self.model = DeepSeekModel(model_name=model_name)
    self.metric = GEval(
      name="ArtifactQuality",
      evaluation_steps=EVALUATION_STEPS,
      evaluation_params=[
        SingleTurnParams.INPUT,
        SingleTurnParams.ACTUAL_OUTPUT,
      ],
      model=self.model,
      threshold=threshold,
      strict_mode=False,
    )

  def evaluate(self, task: str, workspace: Path) -> Judgment:
    actual = ARTIFACT_TEMPLATE.format(
      produced_files=collect_produced_files(workspace),
      tree=collect_tree(workspace),
    )
    input_text = INPUT_TEMPLATE.format(task=task)
    log(
      "judge:artifact",
      f"evaluating: model={self.model.get_model_name()} "
      f"threshold={self.metric.threshold} "
      f"steps={len(EVALUATION_STEPS)} "
      f"input_chars={len(input_text)} actual_chars={len(actual)}",
    )
    test_case = LLMTestCase(input=input_text, actual_output=actual)
    start = time.time()
    self.metric.measure(test_case)
    elapsed = time.time() - start
    score = float(self.metric.score)
    passed = bool(self.metric.is_successful())
    reason = self.metric.reason or ""
    log(
      "judge:artifact",
      f"done in {elapsed:.1f}s: score={score:.3f} "
      f"threshold={self.metric.threshold} pass={passed}",
    )
    if reason:
      log("judge:artifact", f"reason: {reason}")
    return Judgment(name=self.name, passed=passed, score=score, reason=reason)
