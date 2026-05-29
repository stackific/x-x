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
| Anthropic Claude | ⏳ | ⏳ | ⏳ | ⏳ | |
| OpenAI Codex | ⏳ | ⏳ | ⏳ | ⏳ | |
| GitHub Copilot | ⏳ | ⏳ | ⏳ | ⏳ | |
| OpenCode | ⏳ | ⏳ | ⏳ | ⏳ | |
| Pi | ⏳ | ⏳ | ⏳ | ⏳ | |
| Oh My Pi | ⏳ | ⏳ | ⏳ | ⏳ | |
| Cline | ⏳ | ⏳ | ⏳ | ⏳ | |
| Continue | ⏳ | ⏳ | ⏳ | ⏳ | |
| Cursor | ⏳ | ⏳ | ⏳ | ⏳ | |
| Kilo Code | ⏳ | ⏳ | ⏳ | ⏳ | |
| Zed | ⏳ | ⏳ | ⏳ | ⏳ | |

**Skills checklist per cell** (what counts as ✅):

1. `stax init --agents <key> --scope <scope>` exits 0 and prints the
   expected install path.
2. The `SKILL.md` files actually land at the agent's documented
   discovery directory (see
   [agent-skill-and-hook-paths.md](../internal/agent-skill-and-hook-paths.md)).
3. The agent's `/scope` and `/ship` commands resolve to those skills
   in a real session — i.e. typing `/scope ...` invokes the planner,
   typing `/ship` invokes the executor, without manual prompting.
4. `stax skills remove --scope <scope>` exits 0 and deletes ONLY the
   stax-shipped skill directories (any user-authored sibling skills
   survive).

### Notes

- _Add a note here for any non-trivial ✅ / ⚠️ / ❌ cell. Reference the cell by `Agent / OS / scope`._

---

## Hooks

| Agent | macOS / Linux — project | macOS / Linux — user | Windows — project | Windows — user | Last verified |
|---|:-:|:-:|:-:|:-:|:-:|
| Anthropic Claude | ⏳ | ⏳ | ⏳ | ⏳ | |
| OpenAI Codex | ⏳ | ⏳ | ⏳ | ⏳ | |
| GitHub Copilot | ⏳ | ⏳ | ⏳ | ⏳ | |
| OpenCode | ⏳ | ⏳ | ⏳ | ⏳ | |
| Pi | ⏳ | ⏳ | ⏳ | ⏳ | |
| Oh My Pi | ➖ | ➖ | ➖ | ➖ | _not shipped (loader uses caller-passed paths)_ |
| Cline | ➖ | ➖ | ➖ | ➖ | _not shipped (executable scripts; new installer branch needed)_ |
| Continue | ➖ | ➖ | ➖ | ➖ | _not shipped (no discrete event-file format)_ |
| Cursor | ➖ | ➖ | ➖ | ➖ | _not shipped (no documented hook surface)_ |
| Kilo Code | ➖ | ➖ | ➖ | ➖ | _not shipped (no documented event-file format)_ |
| Zed | ➖ | ➖ | ➖ | ➖ | _not shipped (no discrete lifecycle hook surface)_ |

**Hooks checklist per cell** (what counts as ✅):

1. `stax init --agents <key> --scope <scope>` lands the bundle at
   the agent's documented hook location (see
   [agent-skill-and-hook-paths.md](../internal/agent-skill-and-hook-paths.md) →
   "Hooks" table).
2. JSON-merge agents (Claude, Codex, Copilot): re-running `init`
   over a user-edited config preserves the user's top-level keys +
   user-authored hook records, and merges our records additively.
3. TS-plugin agents (OpenCode, Pi): bundled `stax.ts` is
   byte-identical to `agents/<key>/stax.ts` after install, and a
   user edit to it survives a subsequent `init`.
4. In a real session: the agent fires the relevant hook event
   (PostToolUse / postToolUse / tool_result / etc. depending on
   agent vocabulary) and `stax work-items lint` actually runs.
5. `stax skills remove --scope <scope>` un-merges JSON records (or
   deletes byte-equal TS plugins) and leaves user-authored hooks
   intact.

### Notes

- _Add a note here for any non-trivial ✅ / ⚠️ / ❌ cell. Same `Agent / OS / scope` convention as above._

---

## Quick reference: paths each row writes to

| Agent | Skills (project) | Skills (user) | Hooks (project) | Hooks (user) |
|---|---|---|---|---|
| Anthropic Claude | `.claude/skills/` | `~/.claude/skills/` | `.claude/settings.json` | `~/.claude/settings.json` |
| OpenAI Codex | `.agents/skills/` | `~/.agents/skills/` | `.codex/hooks.json` | `~/.codex/hooks.json` |
| GitHub Copilot | `.agents/skills/` | `~/.agents/skills/` | `.github/hooks/stax.json` | `~/.copilot/hooks/stax.json` |
| OpenCode | `.opencode/commands/` | `~/.opencode/commands/` | `.opencode/plugins/stax.ts` | `~/.config/opencode/plugins/stax.ts` |
| Pi | `.agents/skills/` | `~/.agents/skills/` | `.pi/extensions/stax.ts` | `~/.pi/agent/extensions/stax.ts` |
| Oh My Pi | `.agents/skills/` | `~/.agents/skills/` | _n/a_ | _n/a_ |
| Cline | `.cline/skills/` | `~/.cline/skills/` | _n/a_ | _n/a_ |
| Continue | `.continue/skills/` | `~/.continue/skills/` | _n/a_ | _n/a_ |
| Cursor | `.agents/skills/` | `~/.cursor/skills/` | _n/a_ | _n/a_ |
| Kilo Code | `.kilocode/skills/` | `~/.kilocode/skills/` | _n/a_ | _n/a_ |
| Zed | `.agents/skills/` | `~/.agents/skills/` | _n/a_ | _n/a_ |

The single source of truth for these paths is `agentTargets` in
`constants.go`. If a value here drifts from there, the Go side wins.
