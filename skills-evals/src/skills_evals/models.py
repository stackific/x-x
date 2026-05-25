# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""DeepEval model wrapper for DeepSeek's OpenAI-compatible endpoint.

DeepEval ships with first-class OpenAI/Anthropic support but no DeepSeek
backend. We subclass DeepEvalBaseLLM and point the OpenAI SDK at
api.deepseek.com — that endpoint is OpenAI-wire-compatible (see
docs/internal/manually-triggered-workflows.md).
"""

from __future__ import annotations

import json
import os

from deepeval.models.base_model import DeepEvalBaseLLM
from openai import OpenAI

DEEPSEEK_BASE_URL = "https://api.deepseek.com"

# Judges are short, structured calls; flash is fast and cheap enough to run
# on every workflow click. See model-selection table in
# docs/internal/manually-triggered-workflows.md.
DEFAULT_JUDGE_MODEL = "deepseek-v4-flash"


class DeepSeekModel(DeepEvalBaseLLM):
  def __init__(
    self,
    model_name: str = DEFAULT_JUDGE_MODEL,
    api_key: str | None = None,
    base_url: str = DEEPSEEK_BASE_URL,
  ) -> None:
    self.model_name = model_name
    key = api_key or os.environ.get("DEEPSEEK_API_KEY")
    if not key:
      raise RuntimeError("DEEPSEEK_API_KEY not set")
    self._client = OpenAI(api_key=key, base_url=base_url)

  def load_model(self):
    return self._client

  def generate(self, prompt: str, schema=None):
    kwargs: dict = {"temperature": 0}
    if schema is not None:
      kwargs["response_format"] = {"type": "json_object"}
    resp = self._client.chat.completions.create(
      model=self.model_name,
      messages=[{"role": "user", "content": prompt}],
      **kwargs,
    )
    content = resp.choices[0].message.content or ""
    if schema is None:
      return content
    return schema(**json.loads(content))

  async def a_generate(self, prompt: str, schema=None):
    return self.generate(prompt, schema=schema)

  def get_model_name(self) -> str:
    return self.model_name
