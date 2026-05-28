# Usage

```
x-x [subcommand] [flags]
```

Running `x-x` with no arguments prints the about banner and command list. Use one of the subcommands below to do work.

## Commands

| Command                       | Description                                                          |
| ----------------------------- | -------------------------------------------------------------------- |
| `x-x`                         | Print version, copyright, and command list.                          |
| `x-x init [--agents ...] [--scope ...] [--prefix-width N] [--max-plan-lines N] [--review-per task\|plan]` | Install bundled agent skills + seed the project's `.x-plans/` scaffold. |
| `x-x skills remove --user`     | Uninstall bundled x-x skillss from your user scope (`$HOME`).         |
| `x-x skills remove --project`  | Uninstall bundled x-x skillss from the current directory.             |
| `x-x plans next-prefix`        | Print the next unused zero-padded plan prefix for `./.x-plans`.       |
| `x-x plans list`               | List plans in `./.x-plans` with slug, status, and declared systems.   |
| `x-x plans lint`               | Validate every plan file in `./.x-plans` against the project schema.  |
| `x-x plans slugify "<title>"`  | Print the kebab-case slug for a plan title.                          |
| `x-x --version`               | Print the version and exit.                                          |

### `x-x init`

Installs every bundled skill into the locations each agent looks for, then seeds the project's `.x-plans/` scaffold. Five questions run in order; when stdin is a terminal with arrow-key select / multiselect and Shift+Tab back-navigation, so you can revise an earlier answer before submitting the final group. When stdin is piped or redirected, the same questions fall back to line-by-line prompts (which the CI test harness exercises).

1. **Which agents?** Multi-select over every registered agent (Claude Code, Codex CLI, OpenCode, GitHub Copilot CLI today). Blank line / no toggle accepts the default (all agents).
2. **Which scope?** Decides where the bundled SKILLS land. Either way, `.x-plans/` is seeded in the current working directory — that's how the project marker check (`./.x-plans/_config.lock`) recognizes the directory as an x-x project.
   - **This project only** — skills under the current working directory (`.claude/skills/`, `.agents/skills/` shared by Codex and Copilot, `.opencode/commands/`).
   - **All my projects (user scope)** — skills under `$HOME` (`~/.claude/skills/`, `~/.agents/skills/` for Codex and Copilot CLI, `~/.opencode/commands/`).
3. **Prefix width for plan files** — zero-padded width for plan filenames (e.g. width `4` → `0001-foo.md`). Default: `4`.
4. **Maximum lines per plan** — cap enforced by `x-x plans lint`. Keeps AI agents on a short leash: forces them to split sprawling work into smaller, reviewable plans. Default: `30`.
5. **Pause for review after every…** — `task` reviews each EARS criterion as the planner finishes it (tight loop, more interruptions); `plan` reviews only at plan boundaries (looser loop, larger diffs). Default: `task`.

Every prompt has a non-interactive flag twin — pass any subset to skip the matching prompt, or pass all five to drive `init` end-to-end without reading stdin at all (CI / scripted installs):

- `--agents claude,codex,opencode,copilot` — comma-separated agent keys (repeatable). Skips the agent picker. Recognized keys: `claude` (Claude Code), `codex` (Codex CLI), `opencode` (OpenCode), `copilot` (GitHub Copilot CLI). OpenCode resolves slash commands from `.opencode/{command,commands}/**/*.md` (project) and `~/.config/opencode/commands/` (user), keyed off the file's frontmatter `name:`; `x-x init` writes the bundled SKILL.md tree to `.opencode/commands/<skill>/SKILL.md` / `~/.opencode/commands/<skill>/SKILL.md` so each skill registers as both a TUI slash command and an `opencode run --command <skill>` headless invocation (sst/opencode PR #2348).
- `--scope project|user` — skips the scope prompt.
- `--prefix-width N` — positive integer; seeds `prefix_width` in `_config.lock`.
- `--max-plan-lines N` — positive integer; seeds `max_plan_lines` in `_config.lock`.
- `--review-per task|plan` — seeds `review_per` in `_config.lock`.

Values 3–5 land in `.x-plans/_config.lock` and become the lock-file pins for the project — re-running `x-x init` later does NOT refresh them (Cargo.lock / package-lock.json semantics). Never manually edit `.x-plans/_config.lock`.

Codex CLI reads from `.agents/skills` at every level (cwd, repo root, and `$HOME`), per the cross-agent SKILL.md open standard. GitHub Copilot CLI also reads `.agents/skills` at both project and user scope — `~/.agents/skills/` is on Copilot CLI's [official user-scope list](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills) alongside `~/.copilot/skills/`, and we land in the cross-agent path so the bundled `SKILL.md` content (which documents only `.claude/skills` and `.agents/skills`) discovers shared docs correctly. On Windows, `~` resolves to `%USERPROFILE%`, so `~/.claude/skills/` is `%USERPROFILE%\.claude\skills\`, `~/.agents/skills/` is `%USERPROFILE%\.agents\skills\`, and so on. Inside WSL2, paths resolve against the WSL home (`/home/<user>/...`) — install x-x with `INSTALL.sh` from inside WSL to land in the WSL filesystem.

On macOS and Linux at user scope, skill directories are installed as symlinks into `~/.x-x/agents/skills/`, so refreshes to the bundled tree propagate to every project at once. On Windows (and at project scope everywhere), skills are copied. Re-running `x-x init` always overwrites the bundled skill directories with the current release — they are repo-shipped content, not user state.

Agent-specific config files (e.g. `~/.claude/settings.json`) are seeded only when absent — existing files are left alone.

### `x-x skills remove --user`

Walks `~/.claude/skills/`, `~/.agents/skills/`, etc., and removes every entry whose name matches the bundled-skill allowlist (`x-plan`, `x-x` today). The name is the only criterion — symlink targets are not consulted, which means an entry named the same as a bundled skill *will* be removed even if you authored it yourself. Rename any local skill that collides with a bundled one before running this command.

In addition to deleting bundled skill directories, `skill remove` un-merges the hook records `x-x init` previously deep-merged into each agent's JSON config (`~/.claude/settings.json`, `~/.codex/hooks.json`). Subtraction is per-record and uses deep-equality against the currently bundled file under `~/.x-x/agents/<agent>/`: a record that byte-equals one of ours is dropped; a user-tweaked variant (different command, different matcher) is preserved. The file, its top-level non-hook keys, user-added event keys, and any user-authored sibling entries under the same event key all stay.

The following are never touched:

- Folders whose name is not on the bundled-skill allowlist (your own skills sitting alongside ours).
- Anything in the agent config files outside of their `"hooks"` subtree — top-level keys like `"fastMode"` and any user-authored content. Empty arrays or event-key maps left behind by the un-merge are kept as-is; we subtract records, not containers.
- The `.x-plans/` scaffold in cwd. Once `init` writes it (at any scope), it's yours.
- Parent directories (`.claude/`, `.codex/`). Only the `skills/` subdirectory under each may be removed, and only when it is empty after cleanup.

### `x-x skills remove --project`

Same logic as `--user`, but rooted at the current working directory instead of `$HOME`. Run it from the project where you originally did `x-x init`.

`--user` and `--project` are mutually exclusive; exactly one must be passed.

### Project-scope marker check

Every `x-x plans` subcommand and `x-x skills remove --project` require `./.x-plans/` to exist — it's how `x-x` recognizes the current directory as an x-x project. If it's missing, the command prints a two-line diagnostic on stderr and exits `2`:

```
error: not an x-x project: no .x-plans/ in <cwd>
run `x-x init` to initialize the current directory as an x-x project.
```

It runs *after* per-subcommand flag/positional validation, so a usage error (unknown flag, stray positional) still wins the diagnostic and gives the user the most actionable feedback first.

### `x-x plans next-prefix`

Prints the next available zero-padded numeric prefix for a new plan file in `./.x-plans`, e.g. `00004`. Takes no arguments — the directory is not user-configurable.

```bash
x-x plans next-prefix
```

The prefix width is read from `.x-plans/_config.lock` (`prefix_width`), which `x-x init` seeds to `4`. Missing lock file → falls back to the same default.

### `x-x plans list`

Lists every plan in `./.x-plans` whose filename matches `<prefix>-<slug>.md`, one tab-separated row per plan:

```
<slug>\t<status>\t<id1>,<id2>,...
```

The third column lists the kebab-case `id:` of every system the plan declares in its frontmatter `systems:` array (the `id:` keys from `.x-plans/_data_systems.yaml`).

Flags (all repeatable / comma-aware where applicable):

- `--status NAME[,NAME...]` — keep only plans whose `status:` matches.
- `--system ID` — keep only plans whose `systems:` array contains `ID` (OR semantics across multiple `--system` flags). `ID` is the kebab `id:` from `.x-plans/_data_systems.yaml`, not the display name. The flag does not validate the requested id against the registry — an unknown id simply matches zero plans.
- `--order asc|desc` — sort by zero-padded prefix. Default `desc` (latest first). Use `--order=asc` when sequential / oldest-first iteration matters (e.g. `/x-x` ground-truth lookup).
- `--overflow-keywords TERM[,...]` — case-insensitive literal substring(s). **Engages only when** the post-`--status`/`--system` row count exceeds `planListOverflowThreshold` (default 20, in `constants.go`). At or below the threshold the flag is a no-op — the caller pays nothing for declaring an unused narrow.

Overflow-narrow behavior, when it engages:

- ≥1 plan's body contains ≥1 keyword (case-insensitive) → return only matched rows (in the current sort order).
- 0 matches → return the top `planListOverflowThreshold` rows in the current sort order as a fallback summary (never an empty result the caller has to special-case).
- Frontmatter (title, status, systems, …) is *not* searched — body only.
- Keywords are literal substrings; regex metacharacters carry no special meaning (`.` is a dot, `*` is a star).

```bash
x-x plans list
x-x plans list --status valid
x-x plans list --status valid,superseded --system auth-service
x-x plans list --order=asc                                  # /x-x sequential execution
x-x plans list --status valid --system payment-service --overflow-keywords webhook,retry  # narrow on overflow
```

Files matching the filename pattern but missing frontmatter, `status:`, or `systems:` produce a warning on stderr and are skipped (they don't fail the command — for that, use `x-x plans lint`).

### `x-x plans lint`

Validates every `*.md` plan file in `./.x-plans` against the contract: filename pattern (`<prefix>-<slug>.md`), file length (≤ `max_plan_lines` from `_config.lock`, default 30), YAML frontmatter format, mandatory `title:` (first key) and `created:` (last key, ISO 8601 UTC timestamp `YYYY-MM-DDTHH:MM:SSZ`), allowed `status:` values, every id in `systems:` is a known `id:` in `.x-plans/_data_systems.yaml`, every slug in `supersedes:` / `superseded_by:` / `extends:` / `extended_by:` resolves to a sibling plan and is not the plan itself, the `supersedes` ↔ `superseded_by` and `extends` ↔ `extended_by` back links are symmetric across plans, filename slug ↔ `slugify(title)` equality, required body sections (`## Goal`, `## Approach`, `## Tasks`), and the set of EARS subject names (each resolved to its registry id) equals the declared `systems:` id set exactly.

```bash
x-x plans lint
```

Findings go to stdout (one per line, prefixed with the file path); the `<ok>/<failed>` summary goes to stderr. Exit 0 if every file passes, exit 1 if any failed. The project-scope marker check above still applies, so a missing `./.x-plans/` exits `2` rather than passing silently.

### `x-x plans slugify "<title>"`

Prints the kebab-case slug for a plan title — lowercase the input, replace every run of non-`[a-z0-9]` characters with a single `-`, and trim leading/trailing dashes. The author and `x-x plans lint` use the same algorithm, so call this command when picking the filename for a new plan rather than slugifying by eye.

```bash
x-x plans slugify "Add payment retry policy"   # → add-payment-retry-policy
```

Takes exactly one positional argument; quote titles that contain spaces or shell metacharacters. Exits `2` when the argument is missing, when multiple arguments are passed, or when the title contains no characters that survive slugification. No project-scope marker check — slugify is a pure transform and runs from anywhere.

## Examples

```bash
x-x                              # banner + command list
x-x --version                    # prints e.g. v0.1.0

x-x init                              # huh wizard (TTY) or line prompts (piped); five questions
x-x init --agents claude --scope user # skip pickers; the three plan-tooling prompts still ask
x-x init --agents claude,codex --scope project \
         --prefix-width 6 --max-plan-lines 50 --review-per plan  # fully non-interactive

x-x skills remove --user               # uninstall what `x-x init` (user scope) wrote
x-x skills remove --project            # uninstall what `x-x init` (project scope) wrote here

x-x plans next-prefix                  # prints e.g. 00004
x-x plans list --status valid          # tab-separated rows of every valid plan
x-x plans lint                         # lints every .x-plans/*.md against the schema
x-x plans slugify "My new plan"        # prints e.g. my-new-plan
```

## Exit codes

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| `0`  | Success.                                                         |
| `1`  | Runtime error (file I/O, missing source, etc.).                  |
| `2`  | Bad invocation: unknown subcommand, missing/incompatible flag, or project-scope command run outside an x-x project (no `.x-plans/`). |
