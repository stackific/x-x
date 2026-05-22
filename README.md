# x-x by [Stackific Inc.](https://stackific.com)

An evidence-based, spec-driven agent skillset with enterprise accuracy at startup speed. 

## Quick start

```bash
# For macOS and Linux
curl -fsSL https://stackific.com/x-x/INSTALL.sh | sh

# For Windows
Set-ExecutionPolicy Bypass -Scope Process -Force # If only needed
iex (irm https://stackific.com/x-x/INSTALL.ps1)
```

## Documentation

Public docs live in [`docs/public/`](docs/public/README.md):

- [Getting Started](docs/public/getting-started.md)
- [Usage](docs/public/usage.md)

## Development

Common tasks (via [Task](https://taskfile.dev)):

| Task            | What it does                                    |
| --------------- | ----------------------------------------------- |
| `task setup`    | Install git hooks from `lefthook.yml`.          |
| `task run`      | Run the CLI (`task run -- --name Tanzim`).      |
| `task build`    | Cross-compile macOS/Linux/Windows (amd64+arm64) into `./bin/`. |
| `task test`     | Run the full test suite.                        |
| `task lint`     | Run `golangci-lint` with auto-fix.              |
| `task prepush`  | Run every pre-push hook against all files.      |

See [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) for the contribution workflow (DCO sign-off and signed commits are required).

## License

Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Trademark usage is governed separately by [TRADEMARKS.md](TRADEMARKS.md).
