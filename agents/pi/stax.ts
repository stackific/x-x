// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Stackific Inc.
//
// stax / Pi extension.
//
// Runs `stax work-items lint` after every tool result and at session
// shutdown to mirror the claude / codex / opencode hooks shipped in
// sibling agents/<agent>/ directories. Pi's extension API
// (@earendil-works/pi-coding-agent) exposes `pi.on(event, handler)`
// for lifecycle subscription and `pi.exec(cmd, args, opts)` for shell
// invocation — see github.com/badlogic/pi-mono/.../docs/extensions.md.
//
// File ownership: this file is whole-file-owned by stax via
// byte-identity. `stax init` copies it; if you've edited it (any
// byte change), stax leaves it alone on re-runs and won't delete it
// on `stax skills remove`. To customize, edit freely — stax detects
// the edit and treats the file as user-owned thereafter.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

export default function (pi: ExtensionAPI) {
  pi.on("tool_result", async (_event, ctx) => {
    await pi.exec("stax", ["work-items", "lint"], { signal: ctx.signal })
  })
  pi.on("session_shutdown", async (_event, ctx) => {
    await pi.exec("stax", ["work-items", "lint"], { signal: ctx.signal })
  })
}
