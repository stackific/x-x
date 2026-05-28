# Contributing to stax

Thanks for your interest in contributing to **stax by Stackific**. This document explains how to get changes accepted into the project.

## Before You Start

- By contributing, you agree your contributions will be licensed under the [Apache License 2.0](LICENSE), the same license as the project.
- Please read our [Code of Conduct](CODE_OF_CONDUCT.md).
- Please review our [Usage Policy](README.md#usage-policy) which reflects the values of the project.

## Developer Certificate of Origin (DCO)

This project uses the [Developer Certificate of Origin](https://developercertificate.org/) (DCO) in place of a Contributor License Agreement (CLA). The DCO is a lightweight way for contributors to certify that they wrote or otherwise have the right to submit the code they are contributing.

### How to Sign Off

Every commit must include a `Signed-off-by` line with your real name and an email you control:

```
Signed-off-by: Jane Doe <jane.doe@example.com>
```

The easiest way to add this is with the `-s` flag:

```bash
git commit -s -m "Short description of the change"
```

If you forget, you can amend the last commit:

```bash
git commit --amend -s --no-edit
```

Or rewrite a range of commits:

```bash
git rebase --signoff <base-ref>
```

Pull requests with unsigned commits will not be merged. A DCO check runs on every PR.

## Commit Signing

In addition to DCO sign-off, every commit merged to `main` must be **cryptographically signed** (SSH or GPG). This is enforced via branch protection.

Set up signing for this repo:

```bash
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519.pub
git config commit.gpgsign true
```

Your signing key must be [registered with your GitHub account](https://docs.github.com/en/authentication/managing-commit-signature-verification/adding-a-new-ssh-signing-key-to-your-github-account). Unsigned commits will be blocked from merging.

If you need to fix unsigned commits on a PR branch:

```bash
git rebase --signoff --exec 'git commit --amend --no-edit -S' $(git merge-base HEAD origin/main)
git push --force-with-lease
```

For detailed setup instructions, see [docs/internal/commit-signing.md](../docs/internal/commit-signing.md).

### What You Are Certifying

By signing off, you agree to the full text of the DCO 1.1, which in summary states that:

1. The contribution was created in whole or in part by you and you have the right to submit it under the project's license; or
2. The contribution is based on previous work that is appropriately licensed and you have the right to submit it; or
3. The contribution was provided to you by someone who certified (1) or (2), and you have not modified it.

You also understand that the contribution is public and may be maintained indefinitely, and that your sign-off is recorded along with the project.

## How to Contribute

### Reporting Issues

- Search existing issues first.
- Include reproduction steps, expected vs actual behavior, `stax` version, OS, and relevant logs.
- For security issues, do **not** open a public issue. See [Security](#security).

### Proposing Changes

1. Open an issue first for anything non-trivial so we can discuss direction before you invest time.
2. Fork the repo and create a feature branch.
3. Make focused, well-scoped commits. Each commit must be signed off and cryptographically signed (see above).
4. Add or update tests. CI must pass.
5. Update documentation if behavior or interfaces change.
6. Open a pull request against `main`.

### Pull Request Checklist

- [ ] All commits are signed off (DCO) and cryptographically signed
- [ ] Tests added or updated
- [ ] CI is green
- [ ] Docs updated if needed
- [ ] PR description explains the motivation and approach

### Code Style

Follow the conventions already present in the codebase. Run any formatters and linters configured in the repo before opening a PR.

## Security

Please report security vulnerabilities privately to **info@stackific.com** rather than opening a public issue. We will acknowledge within a reasonable window and coordinate disclosure.

## Questions

Open a GitHub Discussion or an issue marked `question`. For anything else, reach out at info@stackific.com.

## License of Contributions

All contributions are licensed under the [Apache License 2.0](LICENSE). You retain copyright to your contributions; you grant Stackific Inc. and recipients of the software the rights described in the Apache License 2.0.
