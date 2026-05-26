# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""DeepEval judge that scores the plan file produced by /x-plan.

Runs after /x-plan finishes and before /x-x is invoked. Looks only at
`<workspace>/.x-plans/*.md` (the plan files), not at any produced code.
Backed by DeepEval's GEval — the rubric is a list of evaluation_steps the
judge LLM scores independently.
"""

from __future__ import annotations

import time
from pathlib import Path

from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, LLMTestCaseParams

from .._logging import log
from ..models import DEFAULT_JUDGE_MODEL, DeepSeekModel
from ..workspace import collect_plan_files
from .base import Judge, Judgment

INPUT_TEMPLATE = """\
The user asked an x-x planner agent to:

{task}

The planner wrote the following plan file(s) under .x-plans/. Each file
begins with `--- <relative-path> ---` then YAML frontmatter then markdown
body.
"""

EVALUATION_STEPS = [
  (
    "Verify exactly one plan file is present (not zero, not two — the task "
    "should produce a single self-contained plan). The plan file is the "
    "actual output below."
  ),
  (
    "Verify the plan's YAML frontmatter is well-formed: `title:` is the "
    "first key; `status: valid`; `systems:` is an inline array of kebab-id "
    "strings; `created:` is the last key and is an ISO 8601 UTC timestamp "
    "(YYYY-MM-DDTHH:MM:SSZ)."
  ),
  (
    "Verify the body has exactly the sections `## Goal`, `## Approach`, "
    "`## Tasks` in that order, with no `## Considerations`, `## Risks`, "
    "`## Out of Scope`, `## Future Work`, or `## Background` sections."
  ),
  (
    "Verify every `## Tasks` checkbox is an EARS criterion using one of the "
    "patterns (`The <system> shall ...`, `While ..., the <system> shall "
    "...`, `When ..., the <system> shall ...`, `If ..., then the <system> "
    "shall ...`, `Where ..., the <system> shall ...`). Reject bare "
    "`the system`, `it`, `the app`, `the service`. Reject `should`, "
    "`may`, `must`, `will`, `can` — only `shall` is allowed for the "
    "response verb."
  ),
  (
    "Verify the plan addresses the task in the input. The Goal section and "
    "the Tasks section together should make the task in the input "
    "achievable; if the plan describes something unrelated, fail."
  ),
]


class PlanJudge(Judge):
  name = "plan"

  def __init__(
    self,
    model_name: str = DEFAULT_JUDGE_MODEL,
    threshold: float = 0.7,
  ) -> None:
    self.model = DeepSeekModel(model_name=model_name)
    self.metric = GEval(
      name="PlanQuality",
      evaluation_steps=EVALUATION_STEPS,
      evaluation_params=[
        LLMTestCaseParams.INPUT,
        LLMTestCaseParams.ACTUAL_OUTPUT,
      ],
      model=self.model,
      threshold=threshold,
      strict_mode=False,
    )

  def evaluate(self, task: str, workspace: Path) -> Judgment:
    plan_text = collect_plan_files(workspace)
    input_text = INPUT_TEMPLATE.format(task=task)
    log(
      "judge:plan",
      f"evaluating: model={self.model.get_model_name()} "
      f"threshold={self.metric.threshold} "
      f"steps={len(EVALUATION_STEPS)} "
      f"input_chars={len(input_text)} actual_chars={len(plan_text)}",
    )
    test_case = LLMTestCase(input=input_text, actual_output=plan_text)
    start = time.time()
    self.metric.measure(test_case)
    elapsed = time.time() - start
    score = float(self.metric.score)
    passed = bool(self.metric.is_successful())
    reason = self.metric.reason or ""
    log(
      "judge:plan",
      f"done in {elapsed:.1f}s: score={score:.3f} "
      f"threshold={self.metric.threshold} pass={passed}",
    )
    if reason:
      log("judge:plan", f"reason: {reason}")
    return Judgment(name=self.name, passed=passed, score=score, reason=reason)
