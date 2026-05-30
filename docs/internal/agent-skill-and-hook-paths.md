# Agent skill & hook paths

Per-agent install paths for **skills** (where stax lands `SKILL.md` files via `stax init`) and **hooks** (where each agent reads its lifecycle-hook config) — verified from each agent's official docs at the time of writing.

The "verified" column links to the page each row was sourced from. Where two locations are listed, both are documented as valid lookup paths.

## Skills

| Agent | Project scope | User / global scope | Docs |
|---|---|---|---|
| Anthropic Claude Code | `.claude/skills/<name>/SKILL.md` | `~/.claude/skills/<name>/SKILL.md` | [code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills) |
| Google Antigravity | `.agents/skills/<name>/SKILL.md` (cross-agent open spec, honored at workspace scope per the docs codelab) | BOTH `~/.gemini/antigravity-cli/skills/<name>/SKILL.md` (CLI-local global skills consumed by the Antigravity CLI `agy`) AND `~/.gemini/config/skills/<name>/SKILL.md` (skills shared across the Antigravity tool family — read by both `agy` and the Antigravity Desktop app, mirroring the role `~/.gemini/config/mcp_config.json` plays for shared MCP servers). The row's `userSkillsRels` slice carries both destinations so a single `--scope user` install lands the bundle at both. | [antigravity.google/docs/skills](https://antigravity.google/docs/skills) and [antigravity.google/docs/gcli-migration](https://antigravity.google/docs/gcli-migration) |
| OpenCode (sst) | `.opencode/commands/<name>.md` | `~/.config/opencode/commands/<name>.md` | [opencode.ai/docs/commands](https://opencode.ai/docs/commands) |
| GitHub Copilot CLI | `.github/skills/<name>/SKILL.md`, `.claude/skills/<name>/SKILL.md`, or `.agents/skills/<name>/SKILL.md` | `~/.copilot/skills/<name>/SKILL.md` or `~/.agents/skills/<name>/SKILL.md` | [docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills) |
| OpenAI Codex | `$CWD/.agents/skills/<name>/SKILL.md` and `$REPO_ROOT/.agents/skills/<name>/SKILL.md` (hierarchical) | `$HOME/.agents/skills/<name>/SKILL.md` | [developers.openai.com/docs/guides/tools-skills](https://developers.openai.com/docs/guides/tools-skills) |
| Cursor | `.agents/skills/<name>/SKILL.md` (cross-agent open spec at workspace scope) | `~/.cursor/skills/<name>/SKILL.md` (Cursor does NOT honor the cross-agent `~/.agents/skills/` fallback at user scope) | [docs.cursor.com/agent](https://docs.cursor.com/agent) |
| Kilo Code (kilocode.ai) | `.kilocode/skills/<name>/SKILL.md` | `~/.kilocode/skills/<name>/SKILL.md` | [kilocode.ai/docs](https://kilocode.ai/docs) |
| Pi (pi.dev) | `.pi/skills/<name>/SKILL.md` or `.agents/skills/<name>/SKILL.md` (walks up from cwd to repo root) | `~/.pi/agent/skills/<name>/SKILL.md` or `~/.agents/skills/<name>/SKILL.md` | [github.com/badlogic/pi-mono/.../docs/skills.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md) |
| Zed | `.agents/skills/<name>/SKILL.md` (cross-agent open spec, honored at workspace scope) | `~/.agents/skills/<name>/SKILL.md` (Zed honors the cross-agent fallback at user scope too) | [zed.dev/docs/ai/agent-panel](https://zed.dev/docs/ai/agent-panel) |

## Hooks

| Agent | Project scope | User / global scope | Format | Docs |
|---|---|---|---|---|
| Anthropic Claude Code | `.claude/settings.json` (key: `hooks`) | `~/.claude/settings.json` (key: `hooks`) | JSON in settings file | [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks) |
| Google Antigravity | `.gemini/settings.json` (key: `hooks`; same `{matcher, hooks:[{type, command}]}` schema as Claude's settings.json) | `~/.gemini/settings.json` (key: `hooks`). The agent layer reads both the Antigravity CLI's `agy` runtime and the Antigravity Desktop app from this path (precedence inherited from Gemini CLI: project `.gemini/settings.json` overrides `~/.gemini/settings.json`). The CLI-only `~/.gemini/antigravity-cli/settings.json` is for CLI-specific auth/model preferences, NOT lifecycle hooks. | JSON in settings file | [antigravity.google/docs/hooks](https://antigravity.google/docs/hooks) |
| OpenCode (sst) | `.opencode/plugins/*.ts` (plugin module exporting `tool.execute.before` / `tool.execute.after` / `session.idle` etc.) | `~/.config/opencode/plugins/*.ts` | TypeScript plugin (no JSON config) | [opencode.ai/docs/plugins](https://opencode.ai/docs/plugins) |
| GitHub Copilot CLI | `.github/hooks/*.json` | `~/.copilot/hooks/*.json` (override via `COPILOT_HOME`) | Standalone JSON files, `{ "version": 1, "hooks": { ... } }` | [docs.github.com/en/copilot/reference/hooks-configuration](https://docs.github.com/en/copilot/reference/hooks-configuration) |
| OpenAI Codex | `.codex/hooks.json` (or inline `[hooks]` table in `.codex/config.toml`) | `~/.codex/hooks.json` (or inline `[hooks]` in `~/.codex/config.toml`) | JSON file or inline TOML | [developers.openai.com/codex/hooks](https://developers.openai.com/codex/hooks) |
| Cursor | not currently exposed as a discrete on-disk hook surface; `.cursor/settings.json` and the `cursor-agent` config drive behavior via `tools:` / `mcp:` declarations rather than lifecycle hooks. | Same — Cursor's editor settings double as the global config. | JSON in `settings.json` | [docs.cursor.com/agent](https://docs.cursor.com/agent) — no documented public hook surface; verify before bundling. |
| Kilo Code (kilocode.ai) | Hook surface isn't pinned to a public reference page yet; the in-product `.kilocode/config.yaml` covers tool + MCP config but no documented `PostToolUse` / `Stop` equivalents. | Same — config is shared across workspace and global scope. | YAML | [kilocode.ai/docs](https://kilocode.ai/docs) — verify before bundling. |
| Pi (pi.dev) | `.pi/extensions/*.ts` (TypeScript module subscribing to `tool_call`, `tool_result`, `session_start`, `session_shutdown`, `before_agent_start`, `message_start`, `message_end`, etc.) | `~/.pi/agent/extensions/*.ts` | TypeScript extension module (no JSON config); 25+ hook events documented | [github.com/badlogic/pi-mono/.../docs/extensions.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) |
| Zed | Zed's hook surface goes through `~/.config/zed/settings.json`'s `assistant:` + `agent:` keys + MCP tool registration rather than a discrete event-file format. | Same — Zed's editor settings double as the global config. | JSON in `settings.json` | [zed.dev/docs/ai/agent-panel](https://zed.dev/docs/ai/agent-panel) — no documented lifecycle hook surface; verify before bundling. |

## Implications for the stax `agentTarget` registry

`agentTargets` in `constants.go` carries `skillsRel` / `userSkillsRels` (skills install path; `userSkillsRels` is a slice so one agent can install into multiple user-scope discovery roots in one shot — Antigravity is the current example) and optional `configSrc` / `configRel` / `userConfigRel` (per-agent config bundle path; the `userConfigRel` override exists for agents whose hook directory differs between project and user scope — Copilot CLI is the current example). `installOneAgentConfigFile` dispatches on extension: `.json` files deep-merge into the user's copy under the top-level `hooks` key; `.ts` files install with whole-file byte-identity ownership (copy on absent, no-op on byte-equal, preserve on user-edit). `stax skills remove` runs the symmetric un-merge / delete-if-byte-equal.

What's shipped today:

- **JSON merge (record-level ownership under top-level `hooks` key)**:
  - Anthropic Claude Code — `agents/claude/settings.json` → `.claude/settings.json` (both scopes).
  - Codex — `agents/codex/hooks.json` → `.codex/hooks.json` (both scopes).
  - Copilot CLI — `agents/copilot/stax.json` → `.github/hooks/stax.json` at project scope, `~/.copilot/hooks/stax.json` at user scope (scope-asymmetric via `userConfigRel`).
  - Google Antigravity — `agents/antigravity/settings.json` → `.gemini/settings.json` (both scopes; same merge contract Claude uses). At user scope the row ALSO ships skills into two destinations in one install — `~/.gemini/antigravity-cli/skills/` and `~/.gemini/config/skills/` — via the `userSkillsRels []string` slice on the registry row. Multi-destination skills are unique to this row today.
- **TypeScript plugin (whole-file byte-identity ownership)**:
  - OpenCode — `agents/opencode/stax.ts` → `.opencode/plugins/stax.ts` at project, `~/.config/opencode/plugins/stax.ts` at user.
  - Pi — `agents/pi/stax.ts` → `.pi/extensions/stax.ts` at project, `~/.pi/agent/extensions/stax.ts` at user.

What's still unshipped, and why:

- **Cursor** — no documented public hook surface yet (per the row above). Skills-only; no `configSrc` until Cursor publishes a config file format.
- **Kilo Code, Zed** — no discrete on-disk hook event format documented; behavior is routed through YAML/JSON settings or MCP tool registration rather than a stax-bundlable file. Skills-only.

## Source policy

Each row was confirmed against the page in its **Docs** column at the time of writing. Where a row says "not officially documented" or "verify before relying", the search surfaced community blogs or contradictory sources rather than a single authoritative reference, and the row should be re-checked before stax ships behaviour that depends on it.
