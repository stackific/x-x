#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# INSTALL_LOCAL.sh — Install the locally-built stax binary on macOS or Linux.
#
# Companion to INSTALL.sh that skips the GitHub-release download path and
# uses an artifact already on disk under ./bin/ (produced by `task build`).
# Intended for dogfooding the install flow without cutting a release.
#
# Usage:
#   task build && ./scripts/INSTALL_LOCAL.sh
#   BIN_DIR=/path/to/bin INSTALL_DIR=/usr/local/bin ./scripts/INSTALL_LOCAL.sh
#
# Environment overrides:
#   BIN_DIR      Directory holding stax-<os>-<arch> artifacts
#                (default: <repo>/bin, derived from this script's location)
#   INSTALL_DIR  Destination directory (default: $HOME/.stax)

set -eu

BINARY="stax"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.stax}"

script_dir=$(cd "$(dirname "$0")" && pwd)
BIN_DIR="${BIN_DIR:-${script_dir}/../bin}"

info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) die "unsupported OS: $os (use scripts/INSTALL_LOCAL.ps1 on Windows)" ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64|amd64)  arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "unsupported architecture: $arch" ;;
esac

asset="${BINARY}-${os}-${arch}"
source_path="${BIN_DIR}/${asset}"

[ -f "$source_path" ] || die "binary not found: ${source_path}
run \`task build\` from the repo root first, or pass BIN_DIR=/path/to/bin"

info "Installing ${source_path} to ${INSTALL_DIR}/${BINARY}"
mkdir -p "${INSTALL_DIR}"
# cp rather than mv — the source artifact under ./bin/ stays available for
# repeat installs and for the other-arch sibling files.
cp "$source_path" "${INSTALL_DIR}/${BINARY}"
chmod +x "${INSTALL_DIR}/${BINARY}"

config_dir="${HOME}/.stax"
mkdir -p "${config_dir}"
chmod 700 "${config_dir}"

# Seed the update-check config so the first post-install invocation does
# not probe the network. Mirrors INSTALL.sh exactly — same JSON structure,
# same version-string parse (last whitespace-separated token on the first
# `--version` line).
installed_version=$("${INSTALL_DIR}/${BINARY}" --version 2>/dev/null | awk 'NR==1 { print $NF; exit }')
[ -n "$installed_version" ] || installed_version=unknown
escaped_version=$(printf '%s' "${installed_version}" | sed 's/\\/\\\\/g; s/"/\\"/g')
cat > "${config_dir}/.config.json" <<EOF
{
  "version": "${escaped_version}",
  "last_checked": $(date +%s)
}
EOF
chmod 600 "${config_dir}/.config.json"

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

# Seed ~/.stax/agents/ from the binary's embed via the dedicated
# post-install hook. Bare `stax` now launches the loopback web UI AND
# requires `<cwd>/.stax/_config.lock` to be present (it's a per-project
# tool from the user's point of view), so it would fail with
# "not a stax project" when invoked from the installer's working
# directory. `post-install` is the installer-only entry point that
# just materialises ~/.stax/agents/ and exits.
info "Seeding ~/.stax/agents/ from binary"
"${INSTALL_DIR}/${BINARY}" post-install >/dev/null

if ensure_on_path; then
  info "Installed. Run: ${BINARY} --help"
fi
