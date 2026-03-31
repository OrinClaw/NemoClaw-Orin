#!/usr/bin/env bash
set -Eeuo pipefail

# install-nemoclaw-cli.sh — Install the NemoClaw CLI on a Jetson host
#
# Clones the NemoClaw repository to ~/NemoClaw and links the CLI into the npm
# global bin directory.
#
# The clone directory must remain in place after installation — nemoclaw onboard
# stages its Docker build context from it at runtime and requires the full
# source tree.
#
# Safe to run multiple times — skips the install if nemoclaw is already on PATH.
#
# Usage:
#   ./install-nemoclaw-cli.sh
#
# Optional environment overrides:
#   NEMOCLAW_CLONE_URL=https://...   Override the NemoClaw git repository URL

NEMOCLAW_CLONE_URL="${NEMOCLAW_CLONE_URL:-https://github.com/NVIDIA/NemoClaw.git}"

log()      { printf '\n==> %s\n' "$*"; }
warn()     { printf '\n[WARN] %s\n' "$*" >&2; }
die()      { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<EOF_USAGE
Usage:
  ./install-nemoclaw-cli.sh

Environment:
  NEMOCLAW_CLONE_URL   Override the NemoClaw git repository URL
                       (default: https://github.com/NVIDIA/NemoClaw.git)
EOF_USAGE
}

ensure_local_bin_on_path() {
  local local_bin="$HOME/.local/bin"
  if [[ -d "$local_bin" && ":$PATH:" != *":$local_bin:"* ]]; then
    export PATH="$local_bin:$PATH"
  fi
}

ensure_npm_bin_on_path() {
  local npm_bin
  npm_bin="$(npm config get prefix 2>/dev/null)/bin"
  if [[ -d "$npm_bin" && ":$PATH:" != *":$npm_bin:"* ]]; then
    export PATH="$npm_bin:$PATH"
  fi
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  touch "$file"
  grep -Fqx "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

redirect_npm_prefix_if_system() {
  # When Node.js is installed system-wide (e.g. via NodeSource apt package),
  # npm's default global prefix is a root-owned path such as /usr or
  # /usr/lib/node_modules.  npm link would then require sudo and fail with
  # EACCES.  Detect that case and redirect to ~/.local before doing anything
  # else so the link target is user-writable.
  local current_prefix
  current_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -z "$current_prefix" || "$current_prefix" == "undefined" \
        || "$current_prefix" == /usr || "$current_prefix" == /usr/* \
        || "$current_prefix" == /opt/* ]]; then
    warn "npm global prefix is a system path (${current_prefix:-unset}) — redirecting to $HOME/.local to avoid needing sudo"
    npm config set prefix "$HOME/.local"
    mkdir -p "$HOME/.local/bin"
  fi
}

install_nemoclaw() {
  need_cmd git
  need_cmd npm

  local clone_dir="$HOME/NemoClaw"

  log "Installing NemoClaw CLI"
  printf 'Clone target: %s\n' "$clone_dir"
  printf 'Repository:   %s\n' "$NEMOCLAW_CLONE_URL"

  # Redirect npm global prefix away from system paths before cloning so that
  # npm link writes to a user-writable location.
  redirect_npm_prefix_if_system

  if [[ -d "$clone_dir" ]]; then
    warn "Clone directory already exists: $clone_dir"
    warn "Pulling latest changes instead of cloning fresh"
    git -C "$clone_dir" pull --ff-only || \
      die "git pull failed in $clone_dir — resolve conflicts or remove the directory and retry"
  else
    git clone "$NEMOCLAW_CLONE_URL" "$clone_dir"
  fi

  (
    cd "$clone_dir"
    npm install --ignore-scripts
    npm link --ignore-scripts
  )

  ensure_npm_bin_on_path
  ensure_local_bin_on_path

  command -v nemoclaw >/dev/null 2>&1 || \
    die "NemoClaw installed but 'nemoclaw' not found in PATH. Check: npm config get prefix"

  local npm_bin
  npm_bin="$(npm config get prefix)/bin"
  ensure_line_in_file "export PATH=\"$npm_bin:\$PATH\"" "$HOME/.bashrc"
  ensure_line_in_file 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"

  hash -r 2>/dev/null || true
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  ensure_local_bin_on_path

  if command -v nemoclaw >/dev/null 2>&1; then
    log "NemoClaw CLI already installed"
    printf 'nemoclaw: %s\n' "$(command -v nemoclaw)"
    exit 0
  fi

  install_nemoclaw

  log "Installed NemoClaw CLI"
  printf 'nemoclaw: %s\n' "$(command -v nemoclaw)"
}

main "$@"
