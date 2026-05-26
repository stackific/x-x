# Getting Started

## Install (released binary)

### macOS / Linux

```bash
curl -fsSL https://stackific.com/x-x/INSTALL.sh | sh
```

### Windows (PowerShell)

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force # If only needed
iex (irm https://stackific.com/x-x/INSTALL.ps1)
```

## First run

```bash
# Run this inside of a project folder
$ x-x init        # installs bundled skills into ~/.claude/skills, ~/.agents/skills, ~/.copilot/skills (or project-local)
```

See [Reference](reference.md) for the full command reference.

## Planning

```bash
/x-plan <specify what you intend to build>
```

## eXecuting

```bash
# This is a continuos execution loop. You can continue to `/x-plan` in one window
# and in another `/x-x` can continue to pickup the next task in line automatically
/x-x
```

## Uninstall

### macOS / Linux

```bash
curl -fsSL https://stackific.com/x-x/UNINSTALL.sh | sh
```

### Windows (PowerShell)

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force # If only needed
irm https://stackific.com/x-x/UNINSTALL.ps1 | iex
```

The uninstaller cleans up the skills it installed into `~/.claude/`, `~/.codex/`, etc., then removes `~/.x-x/` and strips the PATH entry that install added.