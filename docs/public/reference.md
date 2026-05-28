# Usage

```
stax [subcommand] [flags]
```

Running `stax` with no arguments opens <https://google.com> in the OS-default browser (no-op on a headless box — see `stax` below). Use one of the subcommands below to do work.

## Commands

| Command                       | Description                                                          |
| ----------------------------- | -------------------------------------------------------------------- |
| `stax`                         | Open <https://google.com> in the OS-default browser. Skipped automatically when no desktop session is detected (Linux without `DISPLAY` / `WAYLAND_DISPLAY`); in that case a diagnostic is written to stderr. |
| `stax --no-browser`            | Same as bare `stax` but skip the browser launch. Exits silently after seeding `~/.stax/agents/` on first run. Use this in CI or any scripted invocation that should not pop a window. |
| `stax post-install`            | Installer hook subcommand. Triggers the first-run write of `~/.stax/agents/` and exits silently. `INSTALL.sh` / `INSTALL.ps1` use this; end users normally do not. Takes no arguments. |
| `stax init [--agents ...] [--scope ...] [--prefix-width N] [--max-plan-lines N] [--review-per task\|plan]` | Install bundled agent skills + seed the project's `.stax/` scaffold. |
| `stax skills remove --user`     | Uninstall bundled stax skillss from your user scope (`$HOME`).         |
| `stax skills remove --project`  | Uninstall bundled stax skillss from the current directory.             |
| `stax plans next-prefix`        | Print the next unused zero-padded plan prefix for `./.stax`.       |
| `stax plans list`               | List plans in `./.stax` with slug, status, and declared systems.   |
| `stax plans lint`               | Validate every plan file in `./.stax` against the project schema.  |
| `stax plans slugify "<title>"`  | Print the kebab-case slug for a plan title.                          |
| `stax --version`               | Print the version notice and exit. This is what `INSTALL.sh` / `INSTALL.ps1` parse to seed `~/.stax/.config.json`. |

### `stax init`

Installs every bundled skill into the locations each agent looks for, then seeds the project's `.stax/` scaffold.

When stdin is a terminal, prompts use arrow-key select / multiselect with Shift+Tab back-navigation. When stdin is piped or redirected, the same questions fall back to line-by-line prompts.

#### Prompts

1. **Which agents?** Multi-select over every registered agent. List is sorted alphabetically by display name. Blank line accepts the default (all agents).
2. **Which scope?** Project (`<cwd>/...`) or user (`$HOME/...`). `.stax/` is always seeded in cwd regardless of scope — that's the project marker.
3. **Prefix width for plan files** — zero-padded width for plan filenames (width `4` → `0001-foo.md`). Default: `4`.
4. **Maximum lines per plan** — cap enforced by `stax plans lint`. Keeps AI agents on a short leash. Default: `30`.
5. **Pause for review after every…** — `task` (tight loop, more interruptions) or `plan` (looser loop, larger diffs). Default: `task`.

Values 3–5 land in `.stax/_config.lock` and become the lock-file pins. Re-running `stax init` later does NOT refresh them (Cargo.lock / package-lock.json semantics). Never manually edit `.stax/_config.lock`.

#### Flags (non-interactive twins)

Every prompt has a flag — pass any subset to skip the matching prompt, or pass all five to drive `init` end-to-end without reading stdin (CI / scripted installs).

| Flag | Value | Notes |
| --- | --- | --- |
| `--agents` | Comma-separated keys (repeatable) | See "Agents" below for the full key list. |
| `--scope` | `project` \| `user` | |
| `--prefix-width` | positive integer | |
| `--max-plan-lines` | positive integer | |
| `--review-per` | `task` \| `plan` | |

#### Agents

| Key | Display name | Workspace path | User-scope path |
| --- | --- | --- | --- |
| `antigravity` | Antigravity | `.agents/skills/` | `~/.gemini/antigravity/skills/` |
| `claude` | Claude Code | `.claude/skills/` | `~/.claude/skills/` |
| `cline` | Cline | `.cline/skills/` | `~/.cline/skills/` |
| `codex` | Codex CLI | `.agents/skills/` | `~/.agents/skills/` |
| `continue` | Continue | `.continue/skills/` | `~/.continue/skills/` |
| `copilot` | GitHub Copilot CLI | `.agents/skills/` | `~/.agents/skills/` |
| `cursor` | Cursor | `.agents/skills/` | `~/.cursor/skills/` |
| `kilo` | Kilo Code | `.kilocode/skills/` | `~/.kilocode/skills/` |
| `omp` | Oh My Pi | `.agents/skills/` | `~/.agents/skills/` |
| `opencode` | OpenCode | `.opencode/commands/` | `~/.config/opencode/commands/` |
| `pi` | Pi | `.agents/skills/` | `~/.agents/skills/` |
| `zed` | Zed | `.agents/skills/` | `~/.agents/skills/` |

Paths follow each agent's own docs ([Cline](https://docs.cline.bot/customization/overview), [Continue](https://docs.continue.dev/customize/overview), [Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills), [Cursor](https://docs.cursor.com/agent), [Antigravity](https://antigravity.google/docs/skills), [Pi](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/skills.md), [Oh My Pi](https://github.com/can1357/oh-my-pi/blob/main/docs/skills.md), [Zed](https://zed.dev/docs/ai/agent-panel)).

Key path conventions:

- `.agents/skills/` is the cross-agent open spec. Codex, Copilot, Oh My Pi, Pi, Zed read it natively at both scopes.
- Antigravity and Cursor honor `.agents/skills/` at workspace scope but diverge at user scope (Antigravity → `~/.gemini/antigravity/skills/`, Cursor → `~/.cursor/skills/`).
- Cline, Continue, Kilo, Claude, and OpenCode use their own per-agent paths.

#### Install behavior

- **macOS / Linux at user scope** — skills are symlinks into `~/.stax/agents/skills/`, so refreshes to the bundled tree propagate to every project at once.
- **Windows (and project scope everywhere)** — skills are copied. Re-running `stax init` overwrites the bundled skill directories with the current release.
- **Agent-specific config files** (e.g. `~/.claude/settings.json`) are seeded only when absent. Existing files are left alone.
- **Windows / WSL2** — `~` resolves to `%USERPROFILE%`, so `~/.claude/skills/` becomes `%USERPROFILE%\.claude\skills\`. Inside WSL2, paths resolve against the WSL home (`/home/<user>/...`) — install stax with `INSTALL.sh` from inside WSL to land in the WSL filesystem.

### `stax skills remove --user`

Walks every user-scope skills root and removes every entry whose name matches the bundled-skill allowlist (`scope`, `ship` today). Roots walked:

```
~/.claude/skills/
~/.cline/skills/
~/.continue/skills/
~/.cursor/skills/
~/.kilocode/skills/
~/.opencode/commands/
~/.gemini/antigravity/skills/
~/.agents/skills/
```

The name is the only criterion — symlink targets are not consulted, which means an entry named the same as a bundled skill *will* be removed even if you authored it yourself. Rename any local skill that collides with a bundled one before running this command.

In addition to deleting bundled skill directories, `skill remove` un-merges hook records `stax init` previously deep-merged into each agent's JSON config (`~/.claude/settings.json`, `~/.codex/hooks.json`):

- Subtraction is per-record and uses deep-equality against the currently bundled file under `~/.stax/agents/<agent>/`.
- A record that byte-equals one of ours is dropped.
- A user-tweaked variant (different command, different matcher) is preserved.
- The file, its top-level non-hook keys, user-added event keys, and any user-authored sibling entries under the same event key all stay.

The following are never touched:

- Folders whose name is not on the bundled-skill allowlist (your own skills sitting alongside ours).
- Anything in the agent config files outside of their `"hooks"` subtree — top-level keys like `"fastMode"` and any user-authored content. Empty arrays or event-key maps left behind by the un-merge are kept as-is; we subtract records, not containers.
- The `.stax/` scaffold in cwd. Once `init` writes it (at any scope), it's yours.
- Parent directories (`.claude/`, `.codex/`, `.cline/`, `.continue/`, `.cursor/`, `.kilocode/`, `.gemini/antigravity/`). Only the `skills/` (or `commands/`) subdirectory under each may be removed, and only when it is empty after cleanup.

### `stax skills remove --project`

Same logic as `--user`, but rooted at the current working directory instead of `$HOME`. Run it from the project where you originally did `stax init`.

`--user` and `--project` are mutually exclusive; exactly one must be passed.

### Project-scope marker check

Every `stax plans` subcommand and `stax skills remove --project` require `./.stax/` to exist — it's how `stax` recognizes the current directory as a stax project. If it's missing, the command prints a two-line diagnostic on stderr and exits `2`:

```
error: not a stax project: no .stax/ in <cwd>
run `stax init` to initialize the current directory as a stax project.
```

It runs *after* per-subcommand flag/positional validation, so a usage error (unknown flag, stray positional) still wins the diagnostic and gives the user the most actionable feedback first.

### `stax plans next-prefix`

Prints the next available zero-padded numeric prefix for a new plan file in `./.stax`, e.g. `00004`. Takes no arguments — the directory is not user-configurable.

```bash
stax plans next-prefix
```

The prefix width is read from `.stax/_config.lock` (`prefix_width`), which `stax init` seeds to `4`. Missing lock file → falls back to the same default.

### `stax plans list`

Lists every plan in `./.stax` whose filename matches `<prefix>-<slug>.md`, one tab-separated row per plan:

```
<slug>\t<status>\t<id1>,<id2>,...
```

The third column lists the kebab-case `id:` of every system the plan declares in its frontmatter `systems:` array (the `id:` keys from `.stax/_data_systems.yaml`).

Flags (all repeatable / comma-aware where applicable):

- `--status NAME[,NAME...]` — keep only plans whose `status:` matches.
- `--system ID` — keep only plans whose `systems:` array contains `ID` (OR semantics across multiple `--system` flags). `ID` is the kebab `id:` from `.stax/_data_systems.yaml`, not the display name. The flag does not validate the requested id against the registry — an unknown id simply matches zero plans.
- `--order asc|desc` — sort by zero-padded prefix. Default `desc` (latest first). Use `--order=asc` when sequential / oldest-first iteration matters (e.g. `/ship` ground-truth lookup).
- `--overflow-keywords TERM[,...]` — case-insensitive literal substring(s). **Engages only when** the post-`--status`/`--system` row count exceeds `planListOverflowThreshold` (default 20, in `constants.go`). At or below the threshold the flag is a no-op — the caller pays nothing for declaring an unused narrow.

Overflow-narrow behavior, when it engages:

- ≥1 plan's body contains ≥1 keyword (case-insensitive) → return only matched rows (in the current sort order).
- 0 matches → return the top `planListOverflowThreshold` rows in the current sort order as a fallback summary (never an empty result the caller has to special-case).
- Frontmatter (title, status, systems, …) is *not* searched — body only.
- Keywords are literal substrings; regex metacharacters carry no special meaning (`.` is a dot, `*` is a star).

```bash
stax plans list
stax plans list --status valid
stax plans list --status valid,superseded --system auth-service
stax plans list --order=asc                                  # /ship sequential execution
stax plans list --status valid --system payment-service --overflow-keywords webhook,retry  # narrow on overflow
```

Files matching the filename pattern but missing frontmatter, `status:`, or `systems:` produce a warning on stderr and are skipped (they don't fail the command — for that, use `stax plans lint`).

### `stax plans lint`

Validates every `*.md` plan file in `./.stax` against the contract.

**Filename + length checks:**

- Filename matches the pattern `<prefix>-<slug>.md`.
- File length ≤ `max_plan_lines` from `_config.lock` (default 30).
- Filename slug equals `slugify(title)`.

**Frontmatter checks:**

- YAML frontmatter is present and valid.
- Mandatory `title:` (first key) and `created:` (last key, ISO 8601 UTC timestamp `YYYY-MM-DDTHH:MM:SSZ`).
- `status:` is one of the allowed values.
- Every id in `systems:` is a known `id:` in `.stax/_data_systems.yaml`.
- Every slug in `supersedes:` / `superseded_by:` / `extends:` / `extended_by:` resolves to a sibling plan and is not the plan itself.
- `supersedes` ↔ `superseded_by` and `extends` ↔ `extended_by` back-links are symmetric across plans.

**Body checks:**

- Required sections present: `## Goal`, `## Approach`, `## Tasks`.
- The set of EARS subject names (each resolved to its registry id) equals the declared `systems:` id set exactly.

```bash
stax plans lint
```

Findings go to stdout (one per line, prefixed with the file path); the `<ok>/<failed>` summary goes to stderr. Exit 0 if every file passes, exit 1 if any failed. The project-scope marker check above still applies, so a missing `./.stax/` exits `2` rather than passing silently.

### `stax plans slugify "<title>"`

Prints the kebab-case slug for a plan title — lowercase the input, replace every run of non-`[a-z0-9]` characters with a single `-`, and trim leading/trailing dashes. The author and `stax plans lint` use the same algorithm, so call this command when picking the filename for a new plan rather than slugifying by eye.

```bash
stax plans slugify "Add payment retry policy"   # → add-payment-retry-policy
```

Takes exactly one positional argument; quote titles that contain spaces or shell metacharacters. Exits `2` when the argument is missing, when multiple arguments are passed, or when the title contains no characters that survive slugification. No project-scope marker check — slugify is a pure transform and runs from anywhere.

## Examples

```bash
stax                              # opens https://google.com (or stderr diagnostic if headless)
stax --no-browser                 # same, but skip the browser launch (silent)
stax post-install                 # installer hook: seed ~/.stax/agents/ silently
stax --version                    # prints e.g. v0.1.0 (installer-parseable notice)

stax init                              # huh wizard (TTY) or line prompts (piped); five questions
stax init --agents claude --scope user # skip pickers; the three plan-tooling prompts still ask
stax init --agents claude,codex --scope project \
         --prefix-width 6 --max-plan-lines 50 --review-per plan  # fully non-interactive

stax skills remove --user               # uninstall what `stax init` (user scope) wrote
stax skills remove --project            # uninstall what `stax init` (project scope) wrote here

stax plans next-prefix                  # prints e.g. 00004
stax plans list --status valid          # tab-separated rows of every valid plan
stax plans lint                         # lints every .stax/*.md against the schema
stax plans slugify "My new plan"        # prints e.g. my-new-plan
```

## Exit codes

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| `0`  | Success.                                                         |
| `1`  | Runtime error (file I/O, missing source, etc.).                  |
| `2`  | Bad invocation: unknown subcommand, missing/incompatible flag, or project-scope command run outside a stax project (no `.stax/`). |

## Telemetry

`stax` fires anonymous usage pings at `https://stackific.com/stax/t` so the project can see which subcommands are exercised and which agents users install.

Each ping carries: event name, CLI version, OS, arch, CI flag, and a per-process random session id. It does **not** carry file contents, paths, project identifiers, or any persistent machine id. See `docs/internal/telemetry.md` for the full schema and privacy guarantees.

Opt out by setting **either** of these env vars to any non-empty value:

| Env var | Source |
| --- | --- |
| `DO_NOT_TRACK` | [consoledonottrack.com](https://consoledonottrack.com/) — industry-standard. |
| `DISABLE_TELEMETRY` | Project-specific escape hatch. |

Example: `DO_NOT_TRACK=1 stax init ...` (or export it from your shell rc to disable for every invocation).
