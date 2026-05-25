# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Judge registry. Add new judges by mapping a stable name to a class here."""

from __future__ import annotations

from .base import Judge, Judgment
from .rubric import RubricJudge

JUDGES: dict[str, type[Judge]] = {
  RubricJudge.name: RubricJudge,
}

__all__ = ["JUDGES", "Judge", "Judgment", "RubricJudge"]
