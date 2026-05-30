# Stax by [Stackific Inc.](https://stackific.com/stax)

[![E2E test](https://github.com/stackific/stax/actions/workflows/test.yml/badge.svg)](https://github.com/stackific/stax/actions/workflows/test.yml)
[![E2E test / windows](https://github.com/stackific/stax/actions/workflows/test-windows.yml/badge.svg)](https://github.com/stackific/stax/actions/workflows/test-windows.yml)
[![CodeQL](https://github.com/stackific/stax/actions/workflows/codeql.yml/badge.svg)](https://github.com/stackific/stax/actions/workflows/codeql.yml)
[![Go Reference](https://pkg.go.dev/badge/github.com/stackific/stax.svg)](https://pkg.go.dev/github.com/stackific/stax)
[![Go Report Card](https://goreportcard.com/badge/github.com/stackific/stax)](https://goreportcard.com/report/github.com/stackific/stax)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Latest Release](https://img.shields.io/github/v/release/stackific/stax)](https://github.com/stackific/stax/releases/latest)
[![DCO](https://img.shields.io/badge/DCO-required-blue)](https://developercertificate.org/)
[![Conventional Commits](https://img.shields.io/badge/Conventional_Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org/)

An evidence-based, spec-driven agent skillset with enterprise accuracy at startup speed with just 2-skill vocabulary: `/scope` and `/ship`. 

## Quick start

```bash
# For macOS and Linux
curl -fsSL https://stackific.com/stax/install.sh | sh

# For Windows
Set-ExecutionPolicy Bypass -Scope Process -Force # If only needed
iex (irm https://stackific.com/stax/install.ps1)

## Follow the on-screen instructions

# Initialize a stax project
cd <your-project-folder>
stax init

# Launch your AI coding agent and invoke the `/scope` skill
/scope <specify-your-need>

# Execute the next work item in line
/ship
```

## Documentation

Public docs live in [`docs/public/`](docs/public/README.md):

- [Getting Started](docs/public/getting-started.md)
- [Reference](docs/public/reference.md)

## Development

Common tasks (via [Task](https://taskfile.dev)):

| Task            | What it does                                    |
| --------------- | ----------------------------------------------- |
| `task setup`    | Install git hooks from `lefthook.yml`.          |
| `task run`      | Run the CLI (`task run -- --version`).      |
| `task build`    | Cross-compile macOS/Linux/Windows (amd64+arm64) into `./bin/`. |
| `task prepush`  | Run every pre-push hook against all files.      |

See [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) for the contribution workflow (DCO sign-off and signed commits are required).

## What does `stax` mean?

Stacks of work items. The binary writes work items into `.stax/`, and the two skills move them along the line: `/scope` files a new work item, `/ship` works the stack.

## License

Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Trademark usage is governed separately by [TRADEMARKS.md](TRADEMARKS.md).
