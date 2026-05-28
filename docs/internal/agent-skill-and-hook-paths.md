# Agent skill & hook paths

Per-agent install paths for **skills** (where stax lands `SKILL.md` files via `stax init`) and **hooks** (where each agent reads its lifecycle-hook config) — verified from each agent's official docs at the time of writing.

The "verified" column links to the page each row was sourced from. Where two locations are listed, both are documented as valid lookup paths.

## Skills

| Agent | Project scope | User / global scope | Docs |
|---|---|---|---|
| Claude Code | `.claude/skills/<name>/SKILL.md` | `~/.claude/skills/<name>/SKILL.md` | [code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills) |
| OpenCode (sst) | `.opencode/commands/<name>.md` | `~/.config/opencode/commands/<name>.md` | [opencode.ai/docs/commands](https://opencode.ai/docs/commands) |
| GitHub Copilot CLI | `.github/skills/<name>/SKILL.md`, `.claude/skills/<name>/SKILL.md`, or `.agents/skills/<name>/SKILL.md` | `~/.copilot/skills/<name>/SKILL.md` or `~/.agents/skills/<name>/SKILL.md` | [docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills) |
| OpenAI Codex | `$CWD/.agents/skills/<name>/SKILL.md` and `$REPO_ROOT/.agents/skills/<name>/SKILL.md` (hierarchical) | `$HOME/.agents/skills/<name>/SKILL.md` | [developers.openai.com/docs/guides/tools-skills](https://developers.openai.com/docs/guides/tools-skills) |
| Google Antigravity | `.agents/skills/<name>/SKILL.md` (workspace default; `.agent/skills/` is the legacy backward-compatible name) | `~/.gemini/antigravity/skills/<name>/SKILL.md` (shares the `~/.gemini/` config root with Gemini CLI as a sibling subdirectory; Antigravity does NOT honor the cross-agent `~/.agents/skills/` fallback) | [antigravity.google/docs/skills](https://antigravity.google/docs/skills); [codelab — Authoring Antigravity Skills](https://codelabs.developers.google.com/getting-started-with-antigravity-skills) |
| Cline | `.cline/skills/<name>/SKILL.md` | `~/.cline/skills/<name>/SKILL.md` | [docs.cline.bot/customization/overview](https://docs.cline.bot/customization/overview) |
| Continue (continue.dev) | `.continue/skills/<name>/SKILL.md` | `~/.continue/skills/<name>/SKILL.md` | [docs.continue.dev/customize/overview](https://docs.continue.dev/customize/overview) |
| Cursor | `.agents/skills/<name>/SKILL.md` (cross-agent open spec at workspace scope) | `~/.cursor/skills/<name>/SKILL.md` (Cursor does NOT honor the cross-agent `~/.agents/skills/` fallback at user scope) | [docs.cursor.com/agent](https://docs.cursor.com/agent) |
| Kilo Code (kilocode.ai) | `.kilocode/skills/<name>/SKILL.md` | `~/.kilocode/skills/<name>/SKILL.md` | [kilocode.ai/docs](https://kilocode.ai/docs) |
| Pi (pi.dev) | `.pi/skills/<name>/SKILL.md` or `.agents/skills/<name>/SKILL.md` (walks up from cwd to repo root) | `~/.pi/agent/skills/<name>/SKILL.md` or `~/.agents/skills/<name>/SKILL.md` | [github.com/badlogic/pi-mono/.../docs/skills.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md) |
| Oh My Pi (omp, oh-my-pi) | Multi-provider lookup, priority order: `native` (`.omp/skills/`), `claude` (`.claude/skills/`), `claude-plugins`, `agents` (`.agents/skills/`), `codex` (`.codex/skills/`), `opencode` (`.opencode/commands/`) | Same providers, user-scope variants of each path | [github.com/can1357/oh-my-pi/.../docs/skills.md](https://github.com/can1357/oh-my-pi/blob/main/docs/skills.md) |
| Zed | `.agents/skills/<name>/SKILL.md` (cross-agent open spec, honored at workspace scope) | `~/.agents/skills/<name>/SKILL.md` (Zed honors the cross-agent fallback at user scope too) | [zed.dev/docs/ai/agent-panel](https://zed.dev/docs/ai/agent-panel) |

## Hooks

| Agent | Project scope | User / global scope | Format | Docs |
|---|---|---|---|---|
| Claude Code | `.claude/settings.json` (key: `hooks`) | `~/.claude/settings.json` (key: `hooks`) | JSON in settings file | [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks) |
| OpenCode (sst) | `.opencode/plugins/*.ts` (plugin module exporting `tool.execute.before` / `tool.execute.after` / `session.idle` etc.) | `~/.config/opencode/plugins/*.ts` | TypeScript plugin (no JSON config) | [opencode.ai/docs/plugins](https://opencode.ai/docs/plugins) |
| GitHub Copilot CLI | `.github/hooks/*.json` | `~/.copilot/hooks/*.json` (override via `COPILOT_HOME`) | Standalone JSON files, `{ "version": 1, "hooks": { ... } }` | [docs.github.com/en/copilot/reference/hooks-configuration](https://docs.github.com/en/copilot/reference/hooks-configuration) |
| OpenAI Codex | `.codex/hooks.json` (or inline `[hooks]` table in `.codex/config.toml`) | `~/.codex/hooks.json` (or inline `[hooks]` in `~/.codex/config.toml`) | JSON file or inline TOML | [developers.openai.com/codex/hooks](https://developers.openai.com/codex/hooks) |
| Google Antigravity | not officially documented on a public reference; community examples place plugin hooks in `<plugin>/hooks/hooks.json` and settings-format hooks in the workspace settings file | `~/.gemini/antigravity/settings.json` is the documented global config; plugin-bundled `hooks/hooks.json` is the documented plugin format | JSON (two variants — direct top-level events in `settings.json`, wrapped `{"hooks": {...}}` in plugin `hooks.json`) | [antigravity.google/docs/hooks](https://antigravity.google/docs/hooks) — exact filesystem paths weren't surfaced; verify before relying |
| Cline | `.clinerules/hooks/<event-name>` (executable script — bash, Python, etc.; no file extension; name matches the hook event) | `~/Documents/Cline/Rules/Hooks/<event-name>` (legacy global location) | Executable scripts, JSON over stdin/stdout. **macOS / Linux only — no Windows support** | [docs.cline.bot/customization/hooks](https://docs.cline.bot/customization/hooks) |
| Continue (continue.dev) | Continue exposes lifecycle hooks via its custom-context-providers + tool-policies model in `~/.continue/config.yaml`; no per-event-file format like Claude's settings.json. Hook-equivalent behavior runs through `tools:` / `mcpServers:` declarations rather than a discrete hooks file. | Same — global config is the source for all environments. | YAML in `config.yaml` | [docs.continue.dev/customize/overview](https://docs.continue.dev/customize/overview) — no discrete "hooks file" surface; verify before bundling. |
| Cursor | not currently exposed as a discrete on-disk hook surface; `.cursor/settings.json` and the `cursor-agent` config drive behavior via `tools:` / `mcp:` declarations rather than lifecycle hooks. | Same — Cursor's editor settings double as the global config. | JSON in `settings.json` | [docs.cursor.com/agent](https://docs.cursor.com/agent) — no documented public hook surface; verify before bundling. |
| Kilo Code (kilocode.ai) | Hook surface isn't pinned to a public reference page yet; the in-product `.kilocode/config.yaml` covers tool + MCP config but no documented `PostToolUse` / `Stop` equivalents. | Same — config is shared across workspace and global scope. | YAML | [kilocode.ai/docs](https://kilocode.ai/docs) — verify before bundling. |
| Pi (pi.dev) | `.pi/extensions/*.ts` (TypeScript module subscribing to `tool_call`, `tool_result`, `session_start`, `session_shutdown`, `before_agent_start`, `message_start`, `message_end`, etc.) | `~/.pi/agent/extensions/*.ts` | TypeScript extension module (no JSON config); 25+ hook events documented | [github.com/badlogic/pi-mono/.../docs/extensions.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) |
| Oh My Pi (omp, oh-my-pi) | Dynamic module import (omp's current model — TypeScript modules). Legacy shell-style examples mention `.claude/hooks/pre/*` and `.omp/.../hooks/pre/*` but the in-tree implementation is module-based | Equivalent at user scope (`~/.omp/...`, `~/.claude/hooks/pre/*`) | TypeScript modules; supports `session_*`, `before_agent_start`, `agent_start/end`, `turn_start/end`, `tool_call`, `tool_result`, `context`, `auto_compaction_*`, etc. | [github.com/can1357/oh-my-pi/.../docs/hooks.md](https://github.com/can1357/oh-my-pi/blob/main/docs/hooks.md) |
| Zed | Zed's hook surface goes through `~/.config/zed/settings.json`'s `assistant:` + `agent:` keys + MCP tool registration rather than a discrete event-file format. | Same — Zed's editor settings double as the global config. | JSON in `settings.json` | [zed.dev/docs/ai/agent-panel](https://zed.dev/docs/ai/agent-panel) — no documented lifecycle hook surface; verify before bundling. |

## Implications for the stax `agentTarget` registry

`agentTargets` in `constants.go` carries `skillsRel` (skills install path) and optional `configSrc` / `configRel` (per-agent config bundle path). To wire up hooks for a given agent we need a row whose `configSrc` points at a bundled `agents/<key>/<hook-file>` and whose `configRel` points at the agent's documented hook location.

- **Drop-in JSON, easy to bundle**: Claude Code (already wired — `agents/claude/settings.json` → `~/.claude/settings.json`), Codex (already wired — `agents/codex/hooks.json` → `~/.codex/hooks.json`), Copilot CLI (could ship `~/.copilot/hooks/stax.json`), Cursor (would need `.cursor/hooks.json` if added as a target).
- **Executable script bundle**: Cline — would need a bundle of executable scripts at `.clinerules/hooks/<event>`; the current `installAgentConfig` JSON-merge model doesn't fit. macOS/Linux only.
- **TypeScript plugin bundle**: OpenCode, Pi, omp — would need `.ts` files installed at their respective extension paths. Not a config-file shape.
- **Underdocumented (hooks only)**: Antigravity's skill paths are pinned and the row is registered in `agentTargets` (`.agents/skills` workspace, `~/.gemini/antigravity/skills` global), but its hook surfaces aren't on a single authoritative reference page yet — defer a bundled `agents/antigravity/*.json` until antigravity.google/docs/hooks names a concrete filename + envelope format.

## Source policy

Each row was confirmed against the page in its **Docs** column at the time of writing. Where a row says "not officially documented" or "verify before relying", the search surfaced community blogs or contradictory sources rather than a single authoritative reference, and the row should be re-checked before stax ships behaviour that depends on it.
