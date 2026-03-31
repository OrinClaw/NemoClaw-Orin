#!/usr/bin/env bash
set -Eeuo pipefail

# uninstall-nemoclaw-openshell.sh — Full uninstall for NemoClaw + OpenShell
#
# This is intentionally destructive. It removes:
# - NemoClaw/OpenShell CLI links and user-local binaries
# - NemoClaw clone directory (~/NemoClaw)
# - OpenShell/NemoClaw hidden config/state/cache directories
# - OpenShell gateway containers/volumes and related local images
# - setup-added environment lines from ~/.bashrc
#
# It does NOT remove Docker Engine or Node.js itself.

BASHRC="${BASHRC:-$HOME/.bashrc}"
NEMOCLAW_CLONE_DIR="${NEMOCLAW_CLONE_DIR:-$HOME/NemoClaw}"
ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
pass() { printf '  ✓  %s\n' "$*"; }
info() { printf '      %s\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "Missing command: $1 (continuing where possible)"
    return 1
  }
}

remove_path_if_exists() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    rm -rf "$p"
    pass "Removed $p"
  fi
}

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./lib/uninstall-nemoclaw-openshell.sh
  ./lib/uninstall-nemoclaw-openshell.sh --yes

Options:
  --yes     Skip interactive confirmation prompt
  -h, --help
EOF_USAGE
}

ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

need_cmd rm || true
need_cmd sed || true
need_cmd grep || true

npm_prefix=""
if command -v npm >/dev/null 2>&1; then
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
fi

echo ""
echo "FULL UNINSTALL: NemoClaw + OpenShell"
echo ""
echo "This will remove ALL local NemoClaw/OpenShell data and setup state, including:"
echo "  - OpenShell/NemoClaw Docker containers, volumes, and local images"
echo "  - CLI binaries and npm links"
echo "  - ${NEMOCLAW_CLONE_DIR}"
echo "  - hidden config/state/cache directories (for OpenShell/NemoClaw/OpenClaw)"
echo "  - ${ENV_FILE} and related shell wiring"
echo ""
echo "This action is destructive and not reversible."
echo ""

if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Type FULL_UNINSTALL to continue: " confirm
  [[ "$confirm" == "FULL_UNINSTALL" ]] || {
    echo ""
    echo "Cancelled. Nothing changed."
    echo ""
    exit 0
  }
fi

log "Stopping/removing OpenShell gateways (best effort)"
if command -v openshell >/dev/null 2>&1; then
  openshell forward stop 18789 2>/dev/null || true
  openshell gateway stop -g nemoclaw 2>/dev/null || true
  openshell gateway stop -g openshell 2>/dev/null || true
  openshell gateway destroy -g nemoclaw 2>/dev/null || true
  openshell gateway destroy -g openshell 2>/dev/null || true
  pass "OpenShell gateway cleanup attempted"
else
  warn "openshell CLI not found; skipping CLI-driven gateway cleanup"
fi

log "Removing Docker artifacts (best effort)"
if command -v docker >/dev/null 2>&1; then
  # Containers
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    docker rm -f "$c" >/dev/null 2>&1 || true
    pass "Removed container: $c"
  done < <(docker ps -a --format '{{.Names}}' | grep -E '^openshell-cluster-|^openshell-|^nemoclaw' || true)

  # Volumes
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    docker volume rm -f "$v" >/dev/null 2>&1 || true
    pass "Removed volume: $v"
  done < <(docker volume ls --format '{{.Name}}' | grep -E '^openshell-cluster-|^openshell|^nemoclaw' || true)

  # Local patched images + upstream cluster images
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    docker image rm -f "$img" >/dev/null 2>&1 || true
    pass "Removed image: $img"
  done < <(
    docker image ls --format '{{.Repository}}:{{.Tag}}' | \
      grep -E '^(openshell-cluster:(patched-|jetson-legacy-).+|ghcr\.io/nvidia/openshell/cluster:.+)$' || true
  )
else
  warn "docker not found; skipping Docker artifact cleanup"
fi

log "Removing NemoClaw npm link and clone"
if [[ -d "$NEMOCLAW_CLONE_DIR" ]] && command -v npm >/dev/null 2>&1; then
  (
    cd "$NEMOCLAW_CLONE_DIR"
    npm unlink --ignore-scripts >/dev/null 2>&1 || true
  )
  pass "npm unlink attempted in $NEMOCLAW_CLONE_DIR"
fi
remove_path_if_exists "$NEMOCLAW_CLONE_DIR"

if [[ -n "$npm_prefix" ]]; then
  remove_path_if_exists "$npm_prefix/bin/nemoclaw"
  remove_path_if_exists "$npm_prefix/bin/openshell"
  remove_path_if_exists "$npm_prefix/lib/node_modules/nemoclaw"
  remove_path_if_exists "$npm_prefix/lib/node_modules/openshell"
fi

remove_path_if_exists "$HOME/.local/bin/nemoclaw"
remove_path_if_exists "$HOME/.local/bin/openshell"

log "Removing hidden config/state directories"
for d in \
  "$HOME/.config/openshell" \
  "$HOME/.openshell" \
  "$HOME/.cache/openshell" \
  "$HOME/.local/share/openshell" \
  "$HOME/.config/nemoclaw" \
  "$HOME/.nemoclaw" \
  "$HOME/.cache/nemoclaw" \
  "$HOME/.local/share/nemoclaw" \
  "$HOME/.config/openclaw" \
  "$HOME/.openclaw" \
  "$HOME/.cache/openclaw" \
  "$HOME/.local/share/openclaw"; do
  remove_path_if_exists "$d"
done

log "Cleaning shell setup lines"
if [[ -f "$BASHRC" ]]; then
  cp "$BASHRC" "${BASHRC}.uninstall-nemoclaw-openshell.bak"
  info "Backup saved: ${BASHRC}.uninstall-nemoclaw-openshell.bak"

  python3 - "$BASHRC" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

remove_patterns = [
    "jetson-orin.env",
    "OPENSHELL_CLUSTER_IMAGE",
]

remove_exact = {
    'export PATH="$HOME/.local/bin:$PATH"',
}

filtered = []
for line in lines:
    stripped = line.strip()
    if stripped in remove_exact:
        continue
    if any(p in line for p in remove_patterns):
        continue
    filtered.append(line)

while filtered and filtered[-1].strip() == "":
    filtered.pop()
if filtered:
    filtered.append("\n")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(filtered)
PY
  pass "Cleaned $BASHRC"
else
  warn "$BASHRC not found; skipping shell cleanup"
fi

log "Verification"
if command -v openshell >/dev/null 2>&1; then
  warn "'openshell' is still in PATH in this shell: $(command -v openshell)"
else
  pass "openshell not found in PATH"
fi

if command -v nemoclaw >/dev/null 2>&1; then
  warn "'nemoclaw' is still in PATH in this shell: $(command -v nemoclaw)"
else
  pass "nemoclaw not found in PATH"
fi

echo ""
echo "Full uninstall complete."
echo "Open a new terminal to clear stale PATH entries in the current shell."
echo ""
