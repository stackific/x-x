#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Stackific Inc.
#
# uninstall.sh — Remove a stax installation on macOS or Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/stackific/stax/main/scripts/uninstall.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/stackific/stax/main/scripts/uninstall.sh | INSTALL_DIR=/usr/local/bin sh
#
# Environment overrides:
#   INSTALL_DIR  Directory the binary was installed into (default: $HOME/.stax).
#                Must match whatever was passed to install.sh; otherwise the
#                binary is left in place.

set -eu

BINARY="stax"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.stax}"
CONFIG_DIR="${HOME}/.stax"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) die "unsupported OS: $os (use scripts/uninstall.ps1 on Windows)" ;;
esac

# 1. Have the binary clean up the user-scope skills it installed (~/.claude/
# skills, ~/.agents/skills, etc.). Must run BEFORE we delete the binary in
# step 2. Best-effort: if the binary is missing or fails, we warn and keep
# going so the user still gets a partial cleanup.
bin_path="${INSTALL_DIR}/${BINARY}"
if [ -x "$bin_path" ]; then
  info "Removing bundled user-scope skills"
  "$bin_path" skills remove --user || warn "stax skills remove --user failed; continuing"
else
  warn "${bin_path} not found; skipping user-scope skill cleanup"
fi

# 2. Remove the installed binary.
if [ -f "$bin_path" ]; then
  info "Removing ${bin_path}"
  rm -f "$bin_path"
else
  warn "${bin_path} not found; skipping"
fi

# 3. Remove ~/.stax/ (.config.json + agents/ cache + the binary if installed
# there). Guard against INSTALL_DIR being set to something silly like / or $HOME.
if [ -d "$CONFIG_DIR" ]; then
  case "$CONFIG_DIR" in
    "$HOME"|"/"|"")
      die "refusing to remove ${CONFIG_DIR}"
      ;;
  esac
  info "Removing ${CONFIG_DIR}"
  rm -rf "$CONFIG_DIR"
else
  warn "${CONFIG_DIR} not found; skipping"
fi

# 4. Strip the marker block from the user's shell rc file. install.sh writes
# two consecutive lines: the `# stax installer: PATH` marker followed by the
# PATH/fish_add_path line. Remove both, plus a trailing blank line if it ended
# up isolated, to keep the rc file tidy.
rc_file_for_shell() {
  case "$(basename "${SHELL:-/bin/sh}")" in
    zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}

strip_path_block() {
  rc="$1"
  marker="# stax installer: PATH"
  [ -f "$rc" ] || { warn "$rc not found; skipping PATH cleanup"; return 0; }
  grep -qF "$marker" "$rc" || { info "no stax PATH entry in $rc"; return 0; }

  tmp="${rc}.stax-uninstall.$$"
  # Drop the marker line + the line immediately after it (the export / fish_add_path).
  awk -v m="$marker" '
    skip { skip=0; next }
    index($0, m) { skip=1; next }
    { print }
  ' "$rc" > "$tmp"

  # Overwrite in place (preserves the rc file's existing mode/owner).
  cat "$tmp" > "$rc"
  rm -f "$tmp"
  info "Removed stax PATH entry from $rc"
}

strip_path_block "$(rc_file_for_shell)"

info "Uninstalled. The current shell session keeps the old PATH until you open a new terminal."
