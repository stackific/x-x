# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Generic 4-criterion rubric: plan present, artifacts produced, task met,
artifacts well-formed.

Backed by DeepEval's GEval — the rubric is encoded as evaluation_steps so
the judge LLM is scored against each step independently. The aggregate
score is what GEval returns; threshold defaults to 0.7 (pass if >= 0.7).
"""

from __future__ import annotations

from pathlib import Path

from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, LLMTestCaseParams

from ..models import DEFAULT_JUDGE_MODEL, DeepSeekModel
from ..workspace import collect_plan_files, collect_produced_files, collect_tree
from .base import Judge, Judgment

ARTIFACT_TEMPLATE = """\
=== Artifacts ===

Plan files in .x-plans/:
{plan_files}

Produced files (excluding scaffold directories):
{produced_files}

Workspace file tree (scaffold dirs collapsed for readability):
{tree}
"""

EVALUATION_STEPS = [
  (
    "Verify at least one valid plan file exists in the 'Plan files in .x-plans/' "
    "section of the actual output. Valid means YAML frontmatter with `title:` "
    "first, `status: valid`, `systems:` inline array, `created:` ISO 8601 UTC "
    "timestamp last, plus body sections ## Goal, ## Approach, ## Tasks."
  ),
  (
    "Verify the 'Produced files' section contains concrete artifacts "
    "implementing the task in the input (not just the .x-plans/ scaffold)."
  ),
  (
    "Verify the produced artifacts satisfy the task in the input as literally "
    "stated. If the task names specific behaviors (e.g. 'client-side only', "
    "'localStorage persistence'), the artifacts must demonstrate them."
  ),
  (
    "Verify the produced artifacts are syntactically well-formed for their "
    "file type (HTML parses, JS is valid, etc., based on what's visible)."
  ),
]


class RubricJudge(Judge):
  name = "rubric"

  def __init__(
    self,
    model_name: str = DEFAULT_JUDGE_MODEL,
    threshold: float = 0.7,
  ) -> None:
    self.model = DeepSeekModel(model_name=model_name)
    self.metric = GEval(
      name="PlannerExecutorRubric",
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
    artifacts = ARTIFACT_TEMPLATE.format(
      plan_files=collect_plan_files(workspace),
      produced_files=collect_produced_files(workspace),
      tree=collect_tree(workspace),
    )
    test_case = LLMTestCase(input=task, actual_output=artifacts)
    self.metric.measure(test_case)
    return Judgment(
      name=self.name,
      passed=bool(self.metric.is_successful()),
      score=float(self.metric.score),
      reason=self.metric.reason or "",
    )
