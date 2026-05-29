// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.
//
// stax / OpenCode lifecycle plugin.
//
// Runs `stax work-items lint` after every tool execution and at
// session idle to catch unstaged work-item drift the same way the
// claude / codex hooks files do. Mirrors the bundled JSON-hook
// behavior in agents/claude/settings.json + agents/codex/hooks.json
// using OpenCode's plugin API surface (see opencode.ai/docs/plugins).
//
// File ownership: this file is whole-file-owned by stax via
// byte-identity. `stax init` copies it; if you've edited it (any
// byte change), stax will leave it alone on re-runs and won't delete
// it on `stax skills remove`. To customize, edit freely — stax
// detects the edit and treats the file as user-owned thereafter.
import type { Plugin } from "@opencode-ai/plugin"

export const stax: Plugin = async ({ $ }) => {
  return {
    "tool.execute.after": async () => {
      await $`stax work-items lint`.nothrow()
    },
    "session.idle": async () => {
      await $`stax work-items lint`.nothrow()
    },
  }
}
