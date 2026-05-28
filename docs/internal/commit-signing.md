# Commit Signing Guide for `specd`

## What is the DCO and why do we use it?

The **Developer Certificate of Origin (DCO)** is a lightweight alternative to a Contributor License Agreement. Instead of signing a separate legal document, every contributor certifies the origin of their code by adding a line to each commit message:

```
Signed-off-by: Your Name <you@example.com>
```

By adding that line, the contributor asserts (in short) that they wrote the code, or have the right to submit it under the project's license. Full text: https://developercertificate.org/

We chose DCO over a CLA because it is low-friction for contributors and widely recognized in Apache-2.0 projects (Linux kernel, Kubernetes, Docker, etc.).

**Non-negotiable rules:**

1. Every commit merged into `main` must carry a `Signed-off-by` line.
2. The email in the `Signed-off-by` line must match the commit's author email.
3. Commits are blocked from merging if they fail the DCO check.

## What is commit signing and why do we use it?

A Git commit's author field is just a string. Anyone can set `user.name` and `user.email` to any value and commit as "Linus Torvalds <torvalds@kernel.org>". Without signing, there is no way to tell a real commit from an impersonation.

Cryptographic commit signing attaches a signature to each commit, produced by a private key only the author holds. GitHub verifies the signature against a public key registered to the author's account and displays a **Verified** badge. Unsigned or invalid commits show **Unverified** or nothing.

**Why this matters:**

1. We publish binaries. If a malicious commit slipped into `main`, anyone running the binary is exposed. Signatures make impersonation detectable.
2. We accept external contributions. Signed commits give maintainers confidence that a PR from `ahmed-stackific` really came from Ahmed.
3. Supply-chain attestations (SLSA, provenance) build on signed commits. Adopting signing now means we are ready when customers ask.

**Non-negotiable rules:**

1. Every commit merged to `main` must be cryptographically signed.
2. The signing key must be registered to the GitHub account that authored the commit.
3. Unsigned commits are blocked from merging via branch protection.

**Stackific standard: SSH signing.** It is the simpler path, reuses the key you already use to push, and is the modern default. This guide documents SSH signing as the primary path and includes GPG as an appendix for developers who already use GPG or prefer it.

**Verification checklist:**

- [ ] Test PR with an unsigned commit is blocked
- [ ] Test PR with a signed commit shows **Verified** on each commit and merges successfully

## Admin setup

Go below and setup the main branch.

```
URL: https://github.com/apps/dco

1. Install / Configure (if already installed at the user level)
2. Select the `stackific` organization.
3. Only select repositories = specd
4. Click Install.

---
URL: https://github.com/stackific/specd/security

Private vulnerability reporting = Enabled
Code scanning = Default
Copilot Autofix = Off

Protection rules:
- Security alert severity level: Medium or higher
- Standard alert severity level: Errors and Warnings

Secret protection = Enable

Go back again to (if GitHub sends you somewhere else): https://github.com/stackific/specd/security

Code quality findings = Enable

---
URL: https://github.com/stackific/specd/settings

### Configurations

PRs:
- Allow squash merging (uncheck other options)
    - PR title and description

Visibility = Public; otherwise the following configuration will not take effect

Automatically deelete head branches.

---
URL: https://github.com/stackific/specd/settings/rules

### Configurations

Enforcement status = Active
Bypass list = Org admin -> Allow for PRs only
Branch targeting criteria = Include default target

Branch rules:
- Restrict deletions
- Require linear history
- Require signed commits
- Require a PR before merging
    - Required approvals = 1
    - Dismiss stale PR approvals when new commits are pushed
    - Allowed merge methods = Squash
- Require status checks to pass (these won't show up until these are automatically run for the first time, so come back to it, once those are available in the dropdown):
    - Add checks -> DCO (Developer Certificate of Origin)
- Block force pushes
- Require code scanning results:
  - Add tool -> CodeSQL
    - Medium or higher and Errors and Warnings
- Require code quality results:
  - Warnings and higher
```

## Contributing developer's one-time setup (SSH signing)

Do this **once** per machine. You already push to GitHub over SSH, so you already have an SSH key. We are going to tell Git to use that same key to sign commits.

Requires Git **2.34 or newer**. Check with `git --version`. If older, upgrade first (`brew upgrade git`, `apt install git`, etc.).

### Locate your SSH key

List your public keys:

```bash
ls -1 ~/.ssh/*.pub
```

If you do not have one, create an Ed25519 key:

```bash
ssh-keygen -t ed25519 -C "you@stackific.com"
```

Accept the default path. Set a passphrase (strongly recommended; your OS keychain will cache it).

### Register the key as a signing key on GitHub

A single SSH key can be registered twice: once for authentication (pushing) and once for signing. GitHub treats them as separate entries.

1. Copy your public key:

   ```bash
   # macOS
   pbcopy < ~/.ssh/id_ed25519.pub

   # Linux with xclip
   xclip -selection clipboard < ~/.ssh/id_ed25519.pub

   # Or just print and copy manually
   cat ~/.ssh/id_ed25519.pub
   ```

2. Go to https://github.com/settings/keys.
3. Click **New SSH key**.
4. **Title:** something like `laptop-2026-signing`.
5. **Key type:** change from "Authentication Key" to **Signing Key**.
6. Paste the key. Save.

If you also want this key for authentication (pushing), repeat the steps with **Key type: Authentication Key**. The same public key text goes in both entries.

### Configure Git to sign with SSH

Run these in your `specd` clone. We use `--local` so the config
applies to this repo only and will not leak to your other clones.
If this is a work-only machine and you genuinely want this on every
repo, drop `--local` and add `--global` instead.

```bash
# Identity (DCO requirement: author email must match Signed-off-by)
git config --local user.name "Your Full Name"
git config --local user.email "you@stackific.com"

# Developer Certificate of Origin (DCO) auto-signoff
git config --local format.signoff true

# Use SSH (not GPG) as the signing format
git config --local gpg.format ssh

# Point Git at your SSH public key for signing
git config --local user.signingkey ~/.ssh/id_ed25519.pub

# Sign every commit automatically
git config --local commit.gpgsign true

# Sign every tag automatically (recommended)
git config --local tag.gpgsign true
```

### Verification

Push the commit to a throwaway branch and check GitHub:

```bash
git checkout -b signing-test
git push -u origin signing-test
```

On GitHub, navigate to the branch's latest commit. It should show a green **Verified** badge. If it shows **Unverified**, see troubleshooting below.

Clean up:

```bash
git checkout main
git branch -D signing-test
git push origin --delete signing-test
```

### FAQ 1: I've already pushed some commits to a branch

Rewrite the PR branch to use the work email consistently:

```bash
git rebase -i $(git merge-base HEAD origin/main) \
  --exec 'git commit --amend --author="Your Name <you@stackific.com>" --no-edit -s'
git push --force-with-lease
```

This changes both the author line and re-adds a matching signoff. DCO will now pass.

Do this only on your own PR branches. Never rewrite history on `main` or any shared branch.



