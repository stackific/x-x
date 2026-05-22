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
$ x-x
x-x by Stackific, <version>
An evidence-based, spec-driven agent skillset with enterprise accuracy at startup speed.
...

$ x-x init        # installs bundled skills into ~/.claude, ~/.codex (or project-local)
```

See [Usage](usage.md) for the full command reference.

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
