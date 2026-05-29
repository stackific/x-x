#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# install.sh — Download and install the latest stax release on macOS or Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/stackific/stax/main/scripts/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/stackific/stax/main/scripts/install.sh | INSTALL_DIR=/usr/local/bin sh
#
# Environment overrides:
#   INSTALL_DIR  Destination directory (default: $HOME/.stax)
#   VERSION      Specific release tag, e.g. v0.1.0 (default: latest)

set -eu

REPO="stackific/stax"
BINARY="stax"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.stax}"
VERSION="${VERSION:-latest}"

info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) die "unsupported OS: $os (use scripts/install.ps1 on Windows)" ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64|amd64)  arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "unsupported architecture: $arch" ;;
esac

# Pick the first downloader available so the script works on minimal images.
# There is no portable POSIX way to fetch HTTPS without one of these tools,
# so if both are missing we exit with install hints rather than try to
# bootstrap a downloader from nothing.
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
else
  die "neither curl nor wget is on PATH. Install one and re-run:
    Debian/Ubuntu:  sudo apt-get install -y curl
    Fedora/RHEL:    sudo dnf install -y curl
    Alpine:         sudo apk add curl
    Arch:           sudo pacman -S curl
    macOS:          curl ships with macOS; if missing, run 'xcode-select --install'"
fi

asset="${BINARY}-${os}-${arch}"
if [ "$VERSION" = "latest" ]; then
  base="https://github.com/${REPO}/releases/latest/download"
else
  base="https://github.com/${REPO}/releases/download/${VERSION}"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

info "Downloading ${asset}"
fetch "${base}/${asset}"        "${tmpdir}/${asset}"        || die "failed to download ${asset}"

info "Downloading checksums.txt"
fetch "${base}/checksums.txt"   "${tmpdir}/checksums.txt"   || die "failed to download checksums.txt"

info "Verifying SHA-256"
expected=$(awk -v a="$asset" '$2 == a { print $1 }' "${tmpdir}/checksums.txt")
[ -n "$expected" ] || die "asset ${asset} not listed in checksums.txt"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "${tmpdir}/${asset}" | awk '{print $1}')
else
  die "need sha256sum or shasum on PATH"
fi
[ "$expected" = "$actual" ] || die "checksum mismatch: expected $expected, got $actual"

# Best-effort Cosign keyless verification. Skipped silently when cosign is
# absent so the install works on minimal systems; users who care can install
# cosign and re-run, or verify manually from the release page.
if command -v cosign >/dev/null 2>&1; then
  if fetch "${base}/${asset}.bundle" "${tmpdir}/${asset}.bundle" 2>/dev/null; then
    info "Verifying Cosign signature"
    cosign verify-blob \
      --bundle "${tmpdir}/${asset}.bundle" \
      --certificate-identity-regexp "https://github.com/${REPO}/\\.github/workflows/release\\.yml@refs/tags/.*" \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
      "${tmpdir}/${asset}" >/dev/null || die "cosign verification failed"
  fi
fi

info "Installing to ${INSTALL_DIR}/${BINARY}"
mkdir -p "${INSTALL_DIR}"
mv "${tmpdir}/${asset}" "${INSTALL_DIR}/${BINARY}"
chmod +x "${INSTALL_DIR}/${BINARY}"

config_dir="${HOME}/.stax"
mkdir -p "${config_dir}"
chmod 700 "${config_dir}"

# Seed the update-check config. The CLI reads ~/.stax/.config.json on every run
# and consults the GitHub API at most once per hourly to nudge stale installs.
# Writing last_checked=<now> here means the first post-install invocation
# does not probe the network.
# `stax --version` prints the full notice block; the version itself is the
# last whitespace-separated token on the first line ("stax by Stackific, v0.1.0").
installed_version=$("${INSTALL_DIR}/${BINARY}" --version 2>/dev/null | awk 'NR==1 { print $NF; exit }')
[ -n "$installed_version" ] || installed_version=unknown
# Escape any double-quotes / backslashes in the version string so the JSON
# stays valid even if a future --version output ever contains them.
escaped_version=$(printf '%s' "${installed_version}" | sed 's/\\/\\\\/g; s/"/\\"/g')
cat > "${config_dir}/.config.json" <<EOF
{
  "version": "${escaped_version}",
  "last_checked": $(date +%s)
}
EOF
chmod 600 "${config_dir}/.config.json"

# Make INSTALL_DIR available for future shells by appending an export to the
# rc file of the user's interactive shell. We can't modify the parent shell
# of `curl | sh`, so the user must open a new terminal (or source the file)
# for the change to take effect in their current session.
rc_file_for_shell() {
  case "$(basename "${SHELL:-/bin/sh}")" in
    zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}

ensure_on_path() {
  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) return 0 ;;
  esac

  rc=$(rc_file_for_shell)
  marker="# stax installer: PATH"
  if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
    info "${INSTALL_DIR} already added to $rc"
  else
    mkdir -p "$(dirname "$rc")"
    if [ "$(basename "${SHELL:-/bin/sh}")" = "fish" ]; then
      {
        printf '\n%s\n' "$marker"
        printf 'fish_add_path %s\n' "$INSTALL_DIR"
      } >> "$rc"
    else
      {
        printf '\n%s\n' "$marker"
        printf 'export PATH="%s:$PATH"\n' "$INSTALL_DIR"
      } >> "$rc"
    fi
    info "Added ${INSTALL_DIR} to PATH in $rc"
  fi

  printf '\nOpen a new terminal, or run:\n  . %s\n\nthen: %s --help\n' "$rc" "$BINARY"
  return 1
}

# Seed the bundled agents/ library from the binary's embed. `post-install`
# is the dedicated installer subcommand: it triggers the lazy first-run
# write to ~/.stax/agents/ and exits silently. We must not use bare
# `stax` here — that branch launches the loopback web server and blocks
# on the listener, which would hang the installer. The hourly update
# check (still bound to every invocation) handles refreshes from then on.
info "Seeding ~/.stax/agents/ from binary"
"${INSTALL_DIR}/${BINARY}" post-install >/dev/null

if ensure_on_path; then
  info "Installed. Run: ${BINARY} --help"
fi
