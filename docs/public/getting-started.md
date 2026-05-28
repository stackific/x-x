# Getting Started

## Install (released binary)

### macOS / Linux

```bash
curl -fsSL https://stackific.com/stax/INSTALL.sh | sh
```

### Windows (PowerShell)

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force # If only needed
iex (irm https://stackific.com/stax/INSTALL.ps1)
```

## First run

```bash
# Run this inside of a project folder
$ stax init        # installs bundled skills into ~/.claude/skills, ~/.cline/skills, ~/.continue/skills, ~/.cursor/skills, ~/.kilocode/skills, ~/.gemini/antigravity/skills, ~/.opencode/commands, ~/.agents/skills (or project-local)
```

See [Reference](reference.md) for the full command reference.

## Planning

```bash
/scope <specify what you intend to build>
```

## eXecuting

```bash
# This is a continuos execution loop. You can continue to `/scope` in one window
# and in another `/ship` can continue to pickup the next task in line automatically
/ship
```

## Uninstall

### macOS / Linux

```bash
curl -fsSL https://stackific.com/stax/UNINSTALL.sh | sh
```

### Windows (PowerShell)

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force # If only needed
irm https://stackific.com/stax/UNINSTALL.ps1 | iex
```

The uninstaller cleans up the skills it installed into `~/.claude/`, `~/.codex/`, etc., then removes `~/.stax/` and strips the PATH entry that install added.