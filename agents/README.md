# agents/

This directory holds the agent skill definitions that ship with **stax**.

The CLI sparse-clones this folder into `~/.stax/agents/` on first run, so any
file you add here becomes available to a freshly-installed `stax` binary
without re-releasing it.

Layout follows the cross-agent `SKILL.md` open standard so the same skills
can be reused by Claude Code, Codex CLI, and Antigravity / Gemini CLI:

```
agents/
└── <skill-name>/
    ├── SKILL.md       # required: name + description frontmatter + body
    ├── scripts/       # optional
    ├── references/    # optional
    └── assets/        # optional
```
