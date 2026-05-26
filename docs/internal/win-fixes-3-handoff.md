# Windows e2e iteration handoff — branch `win-fixes-3`

A handoff for whoever picks up the `win-fixes-3` branch. The branch's job
is to get `.github/workflows/exp-windows-cli.yml` to a green run on the
GitHub-hosted `windows-latest` runner. Two prior branches got partway:
`windows-test-fixes` (closed) and `win-fixes-2` (merged as commit
`b258423` "fix: windows-only e2e in the GH workflow"). The structural
problems were fixed there; what remains is iterating on assertion-level
Windows-specific mismatches.

## Current state

- **Branch:** `win-fixes-3`, tracking `origin/win-fixes-3` (NOT
  `origin/main` — that's an easy mistake to make with
  `git worktree add -b foo origin/main`; `git branch --unset-upstream`
  before pushing the first time, then `git push -u origin <branch>`).
- **Worktree:** `/Users/t/work/github/stackific/x-x/.worktrees/win-fixes-3`.
- **HEAD:** one commit ahead of `origin/main` —
  `fix: surface stderr on every harness failure + verbose workflow`.
- **PR:** not opened yet; user creates manually if they want one. The
  workflow runs via `workflow_dispatch` without a PR.

## Trigger the workflow

GitHub UI → **Actions** tab → left sidebar → **exp / windows cli smoke**
→ **Run workflow** (top-right) → pick `win-fixes-3` from the branch
dropdown → leave `verbose: true` → click Run workflow.

The workflow is `workflow_dispatch:` only. It does not run on push or PR.
PR state (draft / ready) is irrelevant.

## What's verified green

Run `task prepush` from any worktree on this branch — verifies
- `go vet ./...`
- `govulncheck ./...`
- `go test ./...` (Go unit tests)
- `golangci-lint`
- `scripts/e2e_test.sh` (bash e2e — 573 cases)

All green at the tip of `win-fixes-3`.

## What's NOT verified, in order of risk

1. **PowerShell e2e (`scripts/e2e_test.ps1`) — never run anywhere.**
   180 cases, 467 assertions. The first ~16 ran on a prior CI before
   hitting harness-mechanics bugs that are now fixed. The remaining
   ~164 are unverified end-to-end.

2. **~50–80 Windows-specific assertions written from MS docs.** Topics:
   - reserved filenames (`CON.md`, `AUX.md`, `NUL.md`, `COM1.md`, `LPT1.md`)
   - hidden file attribute (`(Get-Item ...).Attributes = 'Hidden'`)
   - 8.3 short paths via `Scripting.FileSystemObject` COM
   - BOM tolerance in `_config.lock`
   - `cmd.exe` ↔ pwsh argv parity
   - registry PATH write via
     `[Environment]::SetEnvironmentVariable('Path', ..., 'User')`
   - case-insensitive filesystem assertions
   
   Each one's a guess about real Windows behavior. Realistic guess:
   5–15 have wrong expected values that need one-line tweaks.

3. **`scripts/INSTALL_LOCAL.ps1` — never executed on Windows.** Written
   from PowerShell docs; standard APIs (`Copy-Item`,
   `[Environment]::SetEnvironmentVariable`, `New-Item`). Likely OK but
   first-contact untested.

## How to iterate

1. Trigger workflow via Actions UI.
2. If it fails, the log now contains the actual stderr for each failing
   assertion (the harness's `Write-Fail` was upgraded to always print
   the last Invoke-XX command, exit code, stdout, AND stderr — not just
   `got=[X] want=[Y]`).
3. Fix the failing assertions and/or Go code as appropriate.
4. `git push`.
5. Re-trigger.

If something fails before reaching the e2e step (build job, install,
verify-binary), the verbose workflow steps already dump env, paths,
versions, hashes, and full file listings — diagnosable from log alone.

## Hard rules (per AGENTS.md)

- Don't run bare `go build` at repo root (drops `./x-x`). Use
  `task build` for release artifacts; `go vet ./...` or
  `go build -o /dev/null ./...` for compile checks.
- Every CLI change needs Go unit + bash e2e + PowerShell e2e coverage.
  Behavior-neutral cases MUST land in both `e2e_test.sh` and
  `e2e_test.ps1`. Platform-specific cases (POSIX modes, symlinks,
  reserved Windows filenames, etc.) may live in only the relevant file.
- Every interactive prompt must have a non-interactive flag twin.
- `~/.x-x/agents/` is owned by the binary's embed; never hand-edit.
- Path components MUST be named constants in `constants.go`; both bash
  and PowerShell e2e mirror those values at the top of the file. The
  Go unit test `TestE2EShellConstantsMatchGo` enforces parity for bash.

## What NOT to do — lessons from this iteration

- **Don't install pwsh on the Mac without asking.** User has explicitly
  refused. Verification on Windows-specific things is CI-only.
- **Don't weaken assertions to make tests pass.** If a test fails because
  the CLI is wrong, fix the CLI. The user pulled me back on this hard
  ("do not bypass or compromise on anything to get the tests pass").
  Three real CLI fixes landed because of this principle:
  - `runPlansSlugify` dropped `flag.Parse` (was rejecting leading-dash
    titles).
  - `scanHighestPrefix` tightened regex to match `listPlans` shape (was
    counting 5-digit-prefixed files at width=4).
  - `runInit` gated `writePlansScaffold` behind `--scope project` (was
    polluting cwd on user-scope installs).
- **Don't trust the Edit / Read tool blindly in this session.** Multiple
  times my "successful" Edits didn't persist to disk, and Read returned
  stale cached content while `awk`/`grep` saw the truth. Fall back to
  Python via Bash (`python3 - <<'PYEOF' ... PYEOF`) for any non-trivial
  multi-line edit, then verify with `awk 'NR>=N' file`.
- **Don't put `--` in PowerShell call sites expecting it to reach the
  exe.** pwsh's parameter binder always strips `--` (PowerShell/PowerShell#21208).
  For leading-dash args to native exes, use `-- --` (pwsh eats first,
  exe sees second).
- **Don't write unquoted comma-list args** like
  `Invoke-XX plans list --status valid,superseded` in pwsh. The `,` is
  pwsh's array-construction operator; the value becomes an array
  literal and splats into separate args. Quote it: `'valid,superseded'`.
- **Don't run a wide `replace_all` for `Invoke-XX --` → `Invoke-XX`.**
  After the first replacement, `Invoke-XX --version` (in cases that
  legitimately pass `--version` to the exe) becomes a NEW match for the
  pattern on the second pass, eating the space. Use specific anchors:
  `Invoke-XX -- ` (with trailing space) → `Invoke-XX ` (with trailing
  space), and audit the result.
- **Don't make `Invoke-XX` an advanced function** (with `[CmdletBinding()]`
  or `[Parameter()]` decorators). Advanced functions can't access `$args`,
  and any declared positional parameter (like `$Stdin`) silently swallows
  the first positional arg from every call site. Keep it non-advanced
  with no `param()` block — uses `$args` only. Stdin is fed via the
  script-scope variable `$Script:NextStdin`.

## Architecture cheat-sheet

- **`x-x` CLI** — Go binary at repo root. Subcommands:
  - `init` (interactive + flag-driven; installs skills + seeds `.x-plans/`)
  - `skills remove --user|--project`
  - `plans next-prefix|list|lint|slugify`
- **Skills tree** — bundled markdown under `agents/skills/`; installed
  to `.claude/skills/` or `.agents/skills/` per agent target.
- **Plans scaffold** — `.x-plans/_config.lock` + `_data_systems.yaml`
  per-project. Lock file pins prefix width, max plan lines, review-per.
- **Bash e2e** — `scripts/e2e_test.sh`, runs in
  `.github/workflows/test.yml` inside `golang:1.26-bookworm` container
  on every push/PR.
- **PowerShell e2e** — `scripts/e2e_test.ps1`, runs in
  `.github/workflows/exp-windows-cli.yml` (manual). Two-job pipeline:
  Linux container builds via `task build`, uploads `bin/`; Windows
  runner downloads, installs via `INSTALL_LOCAL.ps1`, runs the e2e,
  then `UNINSTALL.ps1`, then asserts clean.
- **`docs/internal/manually-triggered-workflows.md`** — the convention
  doc for `exp-*.yml` workflows; also the DeepSeek-key + Claude-Code-
  with-DeepSeek setup for the agent-eval lineage.

## User preferences

- **Terse.** No filler, no apologies, no sycophancy. State results,
  decisions, blockers. The user does NOT want "Great question!" or
  "Happy to help!" responses.
- **Direct corrections welcome.** When something is wrong, say so.
- **Hates rework.** Sanity-check load-bearing pieces (especially CI
  shape, harness mechanics, parameter binding) BEFORE shipping, not
  after CI fails. The user has paid for many cycles this session
  catching things that should have been obvious.
- **No installing tools without permission.** pwsh, Docker sandbox,
  etc. — ask, don't assume.
- **Memory-aware.** AGENTS.md is the constitution; CLAUDE.md redirects
  to it; the `memory/` system has prior conventions worth checking.

## Files modified on this branch (vs `origin/main`)

```
.github/workflows/exp-windows-cli.yml   # verbose-by-default 2-job pipeline
scripts/e2e_test.ps1                    # harness with always-print-stderr
```

Run `git diff origin/main -- .` to see exact deltas.

## Files to look at first if you're new

1. `docs/internal/manually-triggered-workflows.md` — the convention
   doc covering `exp-*.yml`, secret injection, agent-eval lineage.
2. `AGENTS.md` — hard rules (no bare `go build`, e2e parity, etc.).
3. `scripts/e2e_test.ps1` lines 1–200 — the harness header and
   `Invoke-XX` rewrite that's the load-bearing piece of this work.
4. `.github/workflows/exp-windows-cli.yml` — the workflow shape.
5. `scripts/INSTALL_LOCAL.ps1`, `scripts/UNINSTALL.ps1` — install flow
   the workflow exercises.
