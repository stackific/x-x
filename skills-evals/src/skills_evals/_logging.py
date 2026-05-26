# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""Shared verbose logger.

One module, one function. Prints `HH:MM:SS [component] message` to stderr
with line-buffered flushing so CI logs render in real time. The goal is
that anyone reading a CI log can reconstruct what happened without the
transcript file.
"""

from __future__ import annotations

import sys
import time


def ts() -> str:
  return time.strftime("%H:%M:%S")


def log(component: str, msg: str) -> None:
  print(f"{ts()} [{component}] {msg}", file=sys.stderr, flush=True)
