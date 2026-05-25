# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Judge contract.

A judge takes the original task string and an eval workspace and returns a
pass/fail with a numeric score in [0, 1] plus a free-text reason. Judges
are composable: the CLI runs N of them and the overall run passes iff
every judge passes.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Judgment:
  name: str
  passed: bool
  score: float
  reason: str

  def to_dict(self) -> dict:
    return {
      "name": self.name,
      "pass": self.passed,
      "score": self.score,
      "reason": self.reason,
    }


class Judge(ABC):
  name: str = "base"

  @abstractmethod
  def evaluate(self, task: str, workspace: Path) -> Judgment: ...
