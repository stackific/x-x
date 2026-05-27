# Manually-triggered experimental workflows

This repo carries a small fleet of GitHub Actions workflows under
`.github/workflows/exp-*.yml` that exist to vet specific scenarios — a single
platform, a single agent backend, a single eval scenario — without bolting
onto `push` / `pull_request` triggers. Each one is launched by hand from the
Actions tab. Once a workflow's signal is stable, the plan is to fold it into
a unified workflow with a `mode:` input (see "Merge policy" below).

This doc covers:

- The conventions every `exp-*.yml` follows.
- How the DeepSeek API key is added to repo secrets and consumed.
- The two model tiers and when to use each.
- Why we install Claude Code via `npm` directly rather than running it inside
  Docker's `sbx` sandbox in CI.

For the inventory of `exp-*.yml` files currently in the repo, run
`ls .github/workflows/exp-*.yml` — that's the source of truth, and it changes
faster than this doc would.

## Conventions

- **File naming.** `.github/workflows/exp-<topic>.yml`. `<topic>` is short
  and kebab-cased (`claude-deepseek-judge`). Once a workflow has produced
  consistent signal and is ready to guard PRs / post-merge sanity, it drops
  the `exp-` prefix in the same change that adds the `pull_request:` /
  `push:` triggers — see `.github/workflows/windows-cli.yml` for the
  graduated form.
- **Trigger.** `workflow_dispatch:` only. Never `push:` / `pull_request:` /
  `schedule:` while a workflow is in the `exp-` phase. The point of the
  `exp-` prefix is "I want to start this myself from the Actions tab."
- **Inputs.** Define every knob as a `workflow_dispatch.inputs` field so the
  Actions UI surfaces the dropdown / text box without users editing the YAML.
- **Permissions.** Start with `permissions: contents: read` and widen only
  when a step needs more (e.g., `actions: write` to upload artifacts isn't
  needed; `contents: write` is needed if you start opening PRs).
- **Timeouts.** Set `timeout-minutes:` on every job. The default is 6 hours,
  which is too long for a runaway agent loop.

## Lineages

Two unrelated families of workflows live in this repo. They never merge into
each other.

1. **Standalone single-platform regressions.** E.g. `windows-cli.yml`.
   These run a fixed test matrix on one platform and assert pass/fail. They
   stay as standalone files forever — there's no "later" they merge into.
2. **Agent-eval family.** E.g. `manual-claude-judge.yml`, future
   `manual-codex-judge.yml`, `manual-cursor-judge.yml`. Same planner +
   executor + LLM-judge loop, different agent backends. These will
   eventually fold into a single workflow with an `agent:` input.

## Adding the DeepSeek API key as a repo secret

1. Open the repo on github.com.
2. **Settings → Secrets and variables → Actions → New repository secret.**
3. Name: `DEEPSEEK_API_KEY`.
4. Value: paste a key from <https://platform.deepseek.com/api_keys>.
5. Save.

One secret handles both `deepseek-v4-pro[1m]` and `deepseek-v4-flash` —
DeepSeek bills the account, not the model. Rotate by generating a new key in
the DeepSeek console and updating the GitHub secret in place; in-flight
workflow runs keep the old value.

## Consuming the key

### Claude Code on DeepSeek (Anthropic-compatible endpoint)

Claude Code reads a small set of env vars and routes its Messages-API calls
through them. To point it at DeepSeek's Anthropic-compatible endpoint:

```yaml
env:
  ANTHROPIC_BASE_URL: https://api.deepseek.com/anthropic
  ANTHROPIC_AUTH_TOKEN: ${{ secrets.DEEPSEEK_API_KEY }}
  ANTHROPIC_MODEL: deepseek-v4-pro[1m]
  ANTHROPIC_DEFAULT_OPUS_MODEL: deepseek-v4-pro[1m]
  ANTHROPIC_DEFAULT_SONNET_MODEL: deepseek-v4-pro[1m]
  ANTHROPIC_DEFAULT_HAIKU_MODEL: deepseek-v4-flash
  CLAUDE_CODE_SUBAGENT_MODEL: deepseek-v4-flash
  CLAUDE_CODE_EFFORT_LEVEL: max
```

Pass `--dangerously-skip-permissions` to skip the per-tool approval prompts
that would otherwise hang the run. Use `-p "<prompt>"` for headless execution.

### Direct DeepSeek API calls (OpenAI-compatible endpoint)

The LLM-judge runner under `skills-evals/` is a uv-managed Python project
that uses [DeepEval](https://github.com/confident-ai/deepeval). Judges
subclass `Judge` (`skills-evals/src/skills_evals/judges/base.py`) and
register in `judges/__init__.py`; today there is one (`rubric`), more can
slot in without touching the workflow.

```yaml
- uses: astral-sh/setup-uv@v3
  with:
    enable-cache: true
- working-directory: skills-evals
  run: uv sync --frozen || uv sync
- working-directory: skills-evals
  env:
    DEEPSEEK_API_KEY: ${{ secrets.DEEPSEEK_API_KEY }}
  run: |
    uv run skills-evals \
      --task "..." \
      --workspace /tmp/eval-workspace \
      --output /tmp/judgment.json
```

The DeepSeek model wrapper (`skills-evals/src/skills_evals/models.py`)
points the OpenAI SDK at `https://api.deepseek.com` and authenticates with
`Bearer ${DEEPSEEK_API_KEY}`. See `skills-evals/README.md` for adding
judges and scenarios.

## Model selection

| Model | Total / active params | Context | Use for |
|---|---|---|---|
| `deepseek-v4-pro[1m]` | 1.6T / 49B MoE | 1M tokens | Primary planner / executor (the agent "lead") |
| `deepseek-v4-flash`   | 284B / 13B MoE | 1M tokens | Subagents, judges, bulk/fast paths |

The `[1m]` suffix is recognized by Claude Code's env-var routing and enables
the 1M-token context window; the bare name `deepseek-v4-pro` is what you pass
to the OpenAI-compatible chat-completions endpoint.

## Pricing snapshot (recorded 2026-05-25)

| Model | Input (cache-miss) | Output | Notes |
|---|---|---|---|
| `deepseek-v4-flash` | $0.14 / 1M tok | $0.28 / 1M tok | flat |
| `deepseek-v4-pro`   | $0.435 / 1M tok | $0.87 / 1M tok | during 75% launch discount; reverts to $1.74 / $3.48 after 2026-05-31 15:59 UTC |

Cache-hit input pricing is 1/10 of the cache-miss rate (effective 2026-04-26).

These numbers go stale fast. Re-check at
<https://api-docs.deepseek.com/quick_start/pricing> before quoting them.

## Why direct `npm install`, not Docker `sbx`, for Claude Code in CI

The Docker sandbox toolkit (`sbx`) requires nested virtualization:

- macOS: Sonoma + Apple Silicon (or x86_64 + HV).
- Windows: `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform`.
- Linux: KVM, with nested virt when running inside another VM.

GitHub's standard hosted runners (`ubuntu-latest`, `windows-latest`,
`macos-latest`) are Azure VMs with nested virtualization disabled. `sbx run
claude` will not start on them.

The sandbox's value (filesystem and network isolation, OAuth credential
proxying) doesn't apply in CI either: the runner is already an ephemeral VM
that gets torn down after the job, and we authenticate via a long-lived API
key stored as a GitHub secret rather than an OAuth subscription. Direct
`npm install -g @anthropic-ai/claude-code` + `ANTHROPIC_AUTH_TOKEN` is the
path Anthropic's own `claude-code-action` uses for the same reason.

If you do want sandboxed execution — for instance to give the agent a
pre-baked toolchain that the bare runner lacks — you need either a
self-hosted runner with KVM/HV-V or a GitHub Larger Runner tier that exposes
nested virt. This repo doesn't currently rely on either.

What the sandbox does NOT provide that you might assume: **authentication
bypass**. Both `sbx` and direct `npm install` require either an API key or
an OAuth flow. The sandbox merely proxies whichever credential you provide;
it doesn't grant access without one.

## Merge policy

When a workflow in the agent-eval lineage has produced consistent, useful
signal across multiple runs, it can be merged into a single
`exp-agent-judge.yml` with an `agent:` input ({`claude-deepseek`,
`codex-deepseek`, `cursor-anthropic`, …}). The merged workflow keeps
`workflow_dispatch:` only — it stays manual until we have enough confidence
to route it into CI proper.

Standalone workflows (the Windows CLI smoke, future per-platform smokes) do
not get folded in. They keep their own files indefinitely so a platform
regression is isolated to a single workflow run.
