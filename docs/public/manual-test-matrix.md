# Manual test matrix

Personal scoreboard for hand-driving every shipped agent against a real
session and ticking off the combinations that pass. CI covers the
install / un-merge plumbing (`scripts/e2e_test.sh` + `.ps1`); this
matrix covers what CI can't: whether the agent actually fires the
shipped hook, whether the bundled `/scope` and `/ship` skills land in
the agent's discovery path, and whether both feel right on each OS.

## How to use

Each table cell is a manual checkpoint. Fill in one of:

| Symbol | Meaning |
|---|---|
| ✅ | Tested by me on this OS + scope, works as expected |
| ❌ | Tested, broken — note the symptom in the **Notes** column below the table |
| ⚠️ | Tested, partial pass — note the caveat below |
| ➖ | Not applicable (agent doesn't support this surface, or scope-asymmetric only exists at one scope) |
| ⏳ | Not tested yet |

Leave a cell as `⏳` until you've actually exercised it. The point of
this doc is the gap between **what CI proves** (plumbing) and **what
only a human session can prove** (the agent invokes the right
SKILL.md and the right hook in real life).

Update the **Last verified** date when you finish a row so a stale
cell is visible at a glance.

---

## Skills

| Agent | macOS / Linux — project | macOS / Linux — user | Windows — project | Windows — user | Last verified |
|---|:-:|:-:|:-:|:-:|:-:|
| Anthropic Claude Code | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |
| Cursor | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |
| GitHub Copilot | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |
| Google Antigravity | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |
| Kilo Code | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |
| OpenAI Codex | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |
| OpenCode | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |
| Pi | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |
| Zed | ✅ | ✅ | ✅ | ✅ | May 29, 2026 |

**Skills checklist per cell** (what counts as ✅):

1. `stax init --agents <key> --scope <scope>` exits 0 and prints the
   expected install path.
2. The `SKILL.md` files actually land at the agent's documented
   discovery directory (path per the quick-reference table below).
   For Google Antigravity at user scope: BOTH
   `~/.gemini/antigravity-cli/skills/` (CLI-local) AND
   `~/.gemini/config/skills/` (shared with Antigravity Desktop) must
   contain the bundled skills.
3. The agent's `/scope` and `/ship` commands resolve to those skills
   in a real session — i.e. typing `/scope ...` invokes the planner,
   typing `/ship` invokes the executor, without manual prompting.
4. `stax skills remove --scope <scope>` exits 0 and deletes ONLY the
   stax-shipped skill directories (any user-authored sibling skills
   survive). For Antigravity at user scope, the wipe covers both
   user-scope skill roots.

### Notes

- _Add a note here for any non-trivial ✅ / ⚠️ / ❌ cell. Reference the cell by `Agent / OS / scope`._

---

## Hooks

| Agent | macOS / Linux — project | macOS / Linux — user | Windows — project | Windows — user | Last verified |
|---|:-:|:-:|:-:|:-:|:-:|
| Anthropic Claude Code | ⏳ | ⏳ | ⏳ | ⏳ | |
| Cursor | ➖ | ➖ | ➖ | ➖ | |
| GitHub Copilot | ⏳ | ⏳ | ⏳ | ⏳ | |
| Google Antigravity | ⏳ | ⏳ | ⏳ | ⏳ | |
| Kilo Code | ➖ | ➖ | ➖ | ➖ | |
| OpenAI Codex | ⏳ | ⏳ | ⏳ | ⏳ | |
| OpenCode | ⏳ | ⏳ | ⏳ | ⏳ | |
| Pi | ⏳ | ⏳ | ⏳ | ⏳ | |
| Zed | ➖ | ➖ | ➖ | ➖ | |

**Hooks checklist per cell** (what counts as ✅):

1. `stax init --agents <key> --scope <scope>` lands the bundle at
   the agent's documented hook location (path per the quick-reference
   table below).
2. JSON-merge agents (Claude, Codex, Copilot, Google Antigravity):
   re-running `init` over a user-edited config preserves the user's
   top-level keys + user-authored hook records, and merges our
   records additively.
3. TS-plugin agents (OpenCode, Pi): bundled `stax.ts` is
   byte-identical to `agents/<key>/stax.ts` after install, and a
   user edit to it survives a subsequent `init`.
4. In a real session: the agent fires the relevant hook event
   (PostToolUse / postToolUse / tool_result / etc. depending on
   agent vocabulary) and `stax work-items lint` actually runs. For
   Antigravity, BOTH the Antigravity CLI (`agy`) and the Antigravity
   Desktop app must fire the hook from the shared
   `~/.gemini/settings.json` file at user scope.
5. `stax skills remove --scope <scope>` un-merges JSON records (or
   deletes byte-equal TS plugins) and leaves user-authored hooks
   intact.

### Notes

- _Add a note here for any non-trivial ✅ / ⚠️ / ❌ cell. Same `Agent / OS / scope` convention as above._

---

## Quick reference: paths each row writes to

| Agent | Skills (project) | Skills (user) | Hooks (project) | Hooks (user) |
|---|---|---|---|---|
| Anthropic Claude Code | `.claude/skills/` | `~/.claude/skills/` | `.claude/settings.json` | `~/.claude/settings.json` |
| Cursor | `.agents/skills/` | `~/.cursor/skills/` | _n/a_ | _n/a_ |
| GitHub Copilot | `.agents/skills/` | `~/.agents/skills/` | `.github/hooks/stax.json` | `~/.copilot/hooks/stax.json` |
| Google Antigravity | `.agents/skills/` | `~/.gemini/antigravity-cli/skills/` AND `~/.gemini/config/skills/` | `.gemini/settings.json` | `~/.gemini/settings.json` |
| Kilo Code | `.kilocode/skills/` | `~/.kilocode/skills/` | _n/a_ | _n/a_ |
| OpenAI Codex | `.agents/skills/` | `~/.agents/skills/` | `.codex/hooks.json` | `~/.codex/hooks.json` |
| OpenCode | `.opencode/commands/` | `~/.opencode/commands/` | `.opencode/plugins/stax.ts` | `~/.config/opencode/plugins/stax.ts` |
| Pi | `.agents/skills/` | `~/.agents/skills/` | `.pi/extensions/stax.ts` | `~/.pi/agent/extensions/stax.ts` |
| Zed | `.agents/skills/` | `~/.agents/skills/` | _n/a_ | _n/a_ |

Google Antigravity is the only row that ships skills into two user-scope
destinations in one install: the Antigravity CLI's CLI-local skills root
(`~/.gemini/antigravity-cli/skills/`) AND the Antigravity-tool-family's
shared skills root (`~/.gemini/config/skills/`, read by both the CLI and
the Antigravity Desktop app). Verify presence at both when running the
checklist's user-scope row.

The single source of truth for these paths is `agentTargets` in
`constants.go`. If a value here drifts from there, the Go side wins.
