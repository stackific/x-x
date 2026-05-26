# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
"""LiteLLM proxy pre-call hook: filter non-`function`-typed tools.

Codex CLI ships built-in tools (shell, apply_patch, MCP groupings) using
the OpenAI Responses API tool taxonomy, which includes types like
`namespace` alongside `function`. DeepSeek's chat-completions endpoint
only accepts `type: "function"` and rejects the whole request with HTTP
400 when any other tool type is present.

LiteLLM's stock Responses → Chat translation passes the tool array
through unchanged. This hook runs in LiteLLM's proxy pre-call path and
drops any tool whose `type` is not exactly `"function"` from the request
data before it leaves the proxy.

Trade-off: codex loses access to whatever namespaced tools it shipped
(likely apply_patch as a structured tool and any MCP servers). The
agent still sees its full tool list internally, but the model is only
told about the function-typed subset, so it can't request the dropped
ones. If a scenario depends on a namespaced tool, this is a real
capability loss — surfaced by the smoke test or scenario failure, not
masked.

Logging: every filter operation logs to stderr (CI logs are the only
diagnostic surface).
"""

from __future__ import annotations

import sys
from typing import Any

from litellm.integrations.custom_logger import CustomLogger


def _log(msg: str) -> None:
  print(f"[litellm-hook] {msg}", file=sys.stderr, flush=True)


def _filter_tools(tools: list[Any]) -> tuple[list[Any], list[dict[str, str]]]:
  kept: list[Any] = []
  dropped: list[dict[str, str]] = []
  for idx, tool in enumerate(tools):
    if not isinstance(tool, dict):
      kept.append(tool)
      continue
    ttype = tool.get("type")
    if ttype == "function":
      kept.append(tool)
      continue
    name = (
      tool.get("name")
      or (tool.get("function") or {}).get("name")
      or "(unnamed)"
    )
    dropped.append({"index": str(idx), "type": str(ttype), "name": str(name)})
  return kept, dropped


class FilterNonFunctionTools(CustomLogger):
  """Pre-call hook that strips non-function-typed tools from the request."""

  async def async_pre_call_hook(
    self,
    user_api_key_dict: Any,
    cache: Any,
    data: dict[str, Any],
    call_type: str,
  ) -> dict[str, Any]:
    tools = data.get("tools")
    if not isinstance(tools, list) or not tools:
      return data
    kept, dropped = _filter_tools(tools)
    if dropped:
      _log(
        f"call_type={call_type} model={data.get('model')!r} "
        f"tools before={len(tools)} after={len(kept)} "
        f"dropped={dropped}"
      )
    else:
      _log(
        f"call_type={call_type} model={data.get('model')!r} "
        f"tools={len(tools)} (all function-typed, none dropped)"
      )
    data["tools"] = kept
    return data


proxy_handler_instance = FilterNonFunctionTools()
