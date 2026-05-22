# Usage

```
x-x [subcommand] [flags]
```

Running `x-x` with no arguments prints the about banner and command list. As a side effect (at most once every ~24 hours) it also (a) rewrites `~/.x-x/agents/` from the binary's embedded skill library to keep the global tree in lockstep with the installed binary, and (b) checks GitHub for a newer release and prints an upgrade nudge if one exists. Project-level installs are never touched by this refresh. Use one of the subcommands below to do work.

## Commands

| Command                       | Description                                                          |
| ----------------------------- | -------------------------------------------------------------------- |
| `x-x`                         | Print version, copyright, and command list.                          |
| `x-x init [--agents ...] [--scope ...]` | Install bundled agent skills + seed the project's `.x-plan/` scaffold. |
| `x-x skill remove --user`     | Uninstall bundled x-x skills from your user scope (`$HOME`).         |
| `x-x skill remove --project`  | Uninstall bundled x-x skills from the current directory.             |
| `x-x plan next-prefix`        | Print the next unused zero-padded plan prefix for `./.x-plan`.       |
| `x-x plan list`               | List plans in `./.x-plan` with slug, status, and declared systems.   |
| `x-x plan lint`               | Validate every plan file in `./.x-plan` against the project schema.  |
| `x-x --version`               | Print the version and exit.                                          |

### `x-x init`

Installs every bundled skill into the locations each agent looks for, then seeds the project's `.x-plan/` scaffold. Two prompts run in order:

1. **Which agents?** A numbered multi-select of every registered agent (Claude Code, Codex CLI today). Comma-separated picks; blank line accepts the default (all agents).
2. **Which scope?**
   - **This project only** — writes under the current working directory (`.claude/skills/`, `.agents/skills/`, and seeds `.x-plan/`).
   - **All my projects (user scope)** — writes under `$HOME` (`~/.claude/skills/`, `~/.agents/skills/`).

Both prompts have non-interactive equivalents — use them for CI / scripted installs:

- `--agents claude,codex` — comma-separated agent keys (repeatable). Skips the agent picker.
- `--scope project|user` — skips the scope prompt.

Pass both and `init` runs without reading stdin at all.

Codex CLI reads from `.agents/skills` at every level (cwd, repo root, and `$HOME`), per the cross-agent SKILL.md open standard. On Windows, `~` resolves to `%USERPROFILE%`, so `~/.claude/skills/` is `%USERPROFILE%\.claude\skills\`, `~/.agents/skills/` is `%USERPROFILE%\.agents\skills\`, and so on. Inside WSL2, paths resolve against the WSL home (`/home/<user>/...`) — install x-x with `INSTALL.sh` from inside WSL to land in the WSL filesystem.

On macOS and Linux at user scope, skill directories are installed as symlinks into `~/.x-x/agents/skills/`, so refreshes to the bundled tree propagate to every project at once. On Windows (and at project scope everywhere), skills are copied. Re-running `x-x init` always overwrites the bundled skill directories with the current release — they are repo-shipped content, not user state.

Agent-specific config files (e.g. `~/.claude/settings.json`) are seeded only when absent — existing files are left alone.

When `init` finishes it prints a one-line tip suggesting you commit `.x-plan/` to git. Plan files are first-class repo content (status, declared systems, EARS tasks), not local state — sharing them keeps the team's plan history aligned. The tip is informational only; `init` never touches `.gitignore` for you.

### Global skill library — automatic refresh

`~/.x-x/agents/` holds the bundled skill library shipped inside the `x-x` binary. You don't run a separate command to keep it fresh:

- **First invocation** of `x-x` after install writes the tree from the binary's embed.
- **Every ~24 hours** thereafter, the same code path that performs the update check rewrites `~/.x-x/agents/` from the currently installed binary's embed. This keeps the global library in lockstep with whatever version of `x-x` you have on disk — upgrade the binary, run it, and the skills tree follows.

Project-level installs (`.claude/skills/`, `.agents/skills/`, `.codex/`) are owned by `x-x init` and are never touched by this refresh.

### `x-x skill remove --user`

Walks `~/.claude/skills/`, `~/.agents/skills/`, etc., and removes every entry whose name matches the bundled-skill allowlist (`_x-x_shared`, `x-plan`, `x-x` today). The name is the only criterion — symlink targets are not consulted, which means an entry named the same as a bundled skill *will* be removed even if you authored it yourself. Rename any local skill that collides with a bundled one before running this command.

The following are never touched:

- Folders whose name is not on the bundled-skill allowlist (your own skills sitting alongside ours).
- Agent config files written by `init` — e.g. `~/.claude/settings.json`. Edit or delete them by hand if needed.
- The `.x-plan/` scaffold at project scope. Once `init` writes it, it's yours.
- Parent directories (`.claude/`, `.codex/`). Only the `skills/` subdirectory under each may be removed, and only when it is empty after cleanup.

### `x-x skill remove --project`

Same logic as `--user`, but rooted at the current working directory instead of `$HOME`. Run it from the project where you originally did `x-x init`.

`--user` and `--project` are mutually exclusive; exactly one must be passed.

### Project-scope gate

Every `x-x plan` subcommand and `x-x skill remove --project` require `./.x-plan/` to exist — it's how `x-x` recognizes the current directory as an x-x project. If it's missing, the command prints a two-line diagnostic on stderr and exits `2`:

```
error: not an x-x project: no .x-plan/ in <cwd>
run `x-x init` to initialize the current directory as an x-x project.
```

The gate runs *after* per-subcommand flag/positional validation, so a usage error (unknown flag, stray positional) still wins the diagnostic and gives the user the most actionable feedback first.

### `x-x plan next-prefix`

Prints the next available zero-padded numeric prefix for a new plan file in `./.x-plan`, e.g. `00004`. Takes no arguments — the directory is not user-configurable.

```bash
x-x plan next-prefix
```

The prefix width is read from `.x-plan/_config.lock` (`prefix_width`), which `x-x init` seeds to `5`. Missing lock file → falls back to the same default.

### `x-x plan list`

Lists every plan in `./.x-plan` whose filename matches `<prefix>-<slug>.md`, one tab-separated row per plan, sorted by zero-padded prefix:

```
<slug>\t<status>\t<sys1>,<sys2>,...
```

Filter flags (both repeatable, both comma-aware):

- `--status NAME[,NAME...]` — keep only plans whose `status:` matches. Repeat or comma-separate to accept multiple values.
- `--system NAME` — keep only plans whose `systems:` array contains `NAME` (OR semantics across multiple `--system` flags).

```bash
x-x plan list
x-x plan list --status valid
x-x plan list --status valid,superseded --system Auth
```

Files matching the filename pattern but missing frontmatter, `status:`, or `systems:` produce a warning on stderr and are skipped (they don't fail the command — for that, use `x-x plan lint`).

### `x-x plan lint`

Validates every `*.md` plan file in `./.x-plan` against the contract: filename pattern (`<prefix>-<slug>.md`), file length (≤ `max_plan_lines` from `_config.lock`, default 30), YAML frontmatter shape, allowed `status:` values, `systems:` membership in `.x-plan/_data_systems.yaml`, `supersedes:` slugs resolving to sibling plans, required body sections (`## Goal`, `## Approach`, `## Tasks`), and EARS subjects ↔ `systems:` exact match.

```bash
x-x plan lint
```

Findings go to stdout (one per line, prefixed with the file path); the `<ok>/<failed>` summary goes to stderr. Exit 0 if every file passes, exit 1 if any failed. The project-scope gate above still applies, so a missing `./.x-plan/` exits `2` rather than passing silently.

## Examples

```bash
x-x                              # banner + command list
x-x --version                    # prints e.g. v0.1.0

x-x init                              # prompts for agents + scope, then installs
x-x init --agents claude --scope user # non-interactive: Claude only, at user scope

x-x skill remove --user               # uninstall what `x-x init` (user scope) wrote
x-x skill remove --project            # uninstall what `x-x init` (project scope) wrote here

x-x plan next-prefix                  # prints e.g. 00004
x-x plan list --status valid          # tab-separated rows of every valid plan
x-x plan lint                         # lints every .x-plan/*.md against the schema
```

## Exit codes

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| `0`  | Success.                                                         |
| `1`  | Runtime error (file I/O, missing source, etc.).                  |
| `2`  | Bad invocation: unknown subcommand, missing/incompatible flag, or project-scope command run outside an x-x project (no `.x-plan/`). |
