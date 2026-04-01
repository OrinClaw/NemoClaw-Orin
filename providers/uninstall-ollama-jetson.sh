#!/usr/bin/env bash
set -Eeuo pipefail

# uninstall-ollama-jetson.sh — Remove a local Ollama Docker install on Jetson
#
# Mirrors providers/install-ollama-jetson.sh by removing the Docker resources
# that script typically creates:
#   - the Ollama container
#   - the Ollama image
#   - optionally the Ollama model library volume
#
# The model library volume is handled separately on purpose because deleting it
# removes all locally stored models. Before asking for confirmation, this
# script inventories the models currently present in the volume when possible.
#
# Usage:
#   ./uninstall-ollama-jetson.sh
#   ./uninstall-ollama-jetson.sh --yes
#   ./uninstall-ollama-jetson.sh --yes --remove-models
#
# Optional environment overrides:
#   OLLAMA_CONTAINER_NAME=ollama   Name of the Ollama container to remove
#   OLLAMA_VOLUME=ollama           Docker volume used for model storage
#   OLLAMA_IMAGE=<image>           Extra image reference to remove if present

OLLAMA_CONTAINER_NAME="${OLLAMA_CONTAINER_NAME:-ollama}"
OLLAMA_VOLUME="${OLLAMA_VOLUME:-ollama}"
OLLAMA_IMAGE="${OLLAMA_IMAGE:-}"

ASSUME_YES=false
REMOVE_MODELS=false

DETECTED_IMAGE=""
VOLUME_PRESENT=false
CONTAINER_PRESENT=false
CONTAINER_RUNNING=false

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
pass() { printf '  ✓  %s\n' "$*"; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./uninstall-ollama-jetson.sh [options]

Options:
  --yes             Skip interactive confirmation prompts
  --remove-models   Remove the Ollama model library volume too
  -h, --help        Show this help

Notes:
  - Container and image cleanup do not delete the model library by default.
  - --remove-models deletes the local Ollama model files from Docker volume
    storage after showing the currently detected models.
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)
        ASSUME_YES=true
        shift
        ;;
      --remove-models)
        REMOVE_MODELS=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

detect_state() {
  log "Inspecting local Ollama Docker state"

  CONTAINER_PRESENT=false
  CONTAINER_RUNNING=false
  VOLUME_PRESENT=false
  DETECTED_IMAGE=""

  if docker ps -a --format '{{.Names}}' | grep -Fxq "$OLLAMA_CONTAINER_NAME"; then
    CONTAINER_PRESENT=true
    DETECTED_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$OLLAMA_CONTAINER_NAME" 2>/dev/null || true)"
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq "$OLLAMA_CONTAINER_NAME"; then
    CONTAINER_RUNNING=true
  fi

  if docker volume ls --format '{{.Name}}' | grep -Fxq "$OLLAMA_VOLUME"; then
    VOLUME_PRESENT=true
  fi

  if [[ "$CONTAINER_PRESENT" == "true" ]]; then
    pass "Found container: $OLLAMA_CONTAINER_NAME"
    if [[ -n "$DETECTED_IMAGE" ]]; then
      printf '  Image: %s\n' "$DETECTED_IMAGE"
    fi
  else
    warn "Container not found: $OLLAMA_CONTAINER_NAME"
  fi

  if [[ "$VOLUME_PRESENT" == "true" ]]; then
    pass "Found volume: $OLLAMA_VOLUME"
  else
    warn "Volume not found: $OLLAMA_VOLUME"
  fi
}

nothing_to_remove() {
  [[ "$CONTAINER_PRESENT" != "true" && "$VOLUME_PRESENT" != "true" && -z "$OLLAMA_IMAGE" ]]
}

get_volume_mountpoint() {
  docker volume inspect --format '{{.Mountpoint}}' "$OLLAMA_VOLUME" 2>/dev/null || true
}

print_installed_models_from_volume() {
  local mountpoint="$1"
  python3 - "$mountpoint" <<'PY'
import os
import sys

mountpoint = sys.argv[1]
manifests_root = os.path.join(mountpoint, "models", "manifests")

print("")
print("Detected models in local Ollama library:")

if not os.path.isdir(manifests_root):
    print("  (no model manifests found)")
    raise SystemExit(0)

models = []
for root, _, files in os.walk(manifests_root):
    rel = os.path.relpath(root, manifests_root)
    if rel == ".":
        continue
    for filename in files:
        if filename.startswith("."):
            continue
        parts = rel.split(os.sep)
        if len(parts) < 2:
            continue
        model = "/".join(parts[1:])
        tag = filename
        models.append(f"{model}:{tag}")

if not models:
    print("  (no model manifests found)")
    raise SystemExit(0)

for name in sorted(set(models), key=str.lower):
    print(f"  - {name}")
PY
}

summarize_model_library() {
  log "Checking model library contents"

  if [[ "$VOLUME_PRESENT" != "true" ]]; then
    warn "No Ollama volume present; there is no local model library to inspect"
    return 0
  fi

  local mountpoint
  mountpoint="$(get_volume_mountpoint)"
  if [[ -z "$mountpoint" || ! -d "$mountpoint" ]]; then
    warn "Could not inspect Docker volume mountpoint for $OLLAMA_VOLUME"
    return 0
  fi

  print_installed_models_from_volume "$mountpoint"
}

offer_model_volume_removal() {
  [[ "$REMOVE_MODELS" == "true" ]] && return 0
  [[ "$VOLUME_PRESENT" == "true" ]] || return 0
  [[ "$ASSUME_YES" != "true" ]] || return 0

  echo ""
  echo "Do you also want to remove the local Ollama model library?"
  echo "Keeping it is the safer default and lets a future Ollama container reuse the models."
  echo ""
  read -r -p "Remove model library volume ${OLLAMA_VOLUME}? [y/N] " reply
  case "${reply:-}" in
    y|Y|yes|YES)
      REMOVE_MODELS=true
      ;;
    *)
      REMOVE_MODELS=false
      ;;
  esac
}

confirm_uninstall() {
  echo ""
  echo "Ollama Uninstall for Jetson"
  echo "JetsonHacks — https://github.com/jetsonhacks/NemoClaw-Orin"
  echo ""
  echo "This will remove the local Ollama Docker install created by"
  echo "providers/install-ollama-jetson.sh."
  echo ""
  echo "Planned actions:"
  echo "  - Remove container: ${OLLAMA_CONTAINER_NAME}"
  if [[ -n "$DETECTED_IMAGE" ]]; then
    echo "  - Remove image: ${DETECTED_IMAGE}"
  elif [[ -n "$OLLAMA_IMAGE" ]]; then
    echo "  - Remove image override if present: ${OLLAMA_IMAGE}"
  else
    echo "  - Remove the container image if it can be identified locally"
  fi
  if [[ "$REMOVE_MODELS" == "true" ]]; then
    echo "  - Remove model library volume: ${OLLAMA_VOLUME}"
  else
    echo "  - Keep model library volume: ${OLLAMA_VOLUME}"
  fi
  echo ""
  echo "Keeping the model library is the safer default."
  echo "Removing the volume deletes the local Ollama models from disk."
  echo ""

  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi

  read -r -p "Type REMOVE_OLLAMA to continue: " confirm
  [[ "$confirm" == "REMOVE_OLLAMA" ]] || {
    echo ""
    echo "Cancelled. Nothing changed."
    echo ""
    exit 0
  }
}

confirm_model_volume_removal() {
  [[ "$REMOVE_MODELS" == "true" ]] || return 0

  if [[ "$VOLUME_PRESENT" != "true" ]]; then
    warn "Model volume removal requested, but volume $OLLAMA_VOLUME does not exist"
    return 0
  fi

  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi

  echo ""
  echo "Model library deletion was requested."
  echo "This removes all locally stored Ollama models in Docker volume ${OLLAMA_VOLUME}."
  echo ""

  read -r -p "Type DELETE_MODELS to remove the model library volume: " confirm
  [[ "$confirm" == "DELETE_MODELS" ]] || {
    echo ""
    echo "Cancelled model library deletion. The Ollama uninstall will continue without removing models."
    echo ""
    REMOVE_MODELS=false
  }
}

remove_container() {
  log "Removing Ollama container"

  if [[ "$CONTAINER_PRESENT" != "true" ]]; then
    pass "No container named ${OLLAMA_CONTAINER_NAME} — nothing to remove"
    return 0
  fi

  docker rm -f "$OLLAMA_CONTAINER_NAME" >/dev/null
  pass "Removed container: $OLLAMA_CONTAINER_NAME"
}

remove_image_if_present() {
  log "Removing Ollama image"

  local image_to_remove="${DETECTED_IMAGE:-$OLLAMA_IMAGE}"
  if [[ -z "$image_to_remove" ]]; then
    warn "No image reference detected; skipping image removal"
    return 0
  fi

  if docker image inspect "$image_to_remove" >/dev/null 2>&1; then
    docker image rm -f "$image_to_remove" >/dev/null || \
      warn "Could not remove image: $image_to_remove"
    if ! docker image inspect "$image_to_remove" >/dev/null 2>&1; then
      pass "Removed image: $image_to_remove"
    fi
  else
    pass "Image not present locally: $image_to_remove"
  fi
}

remove_model_volume_if_requested() {
  [[ "$REMOVE_MODELS" == "true" ]] || return 0

  log "Removing Ollama model library volume"

  if [[ "$VOLUME_PRESENT" != "true" ]]; then
    pass "No volume named ${OLLAMA_VOLUME} — nothing to remove"
    return 0
  fi

  docker volume rm "$OLLAMA_VOLUME" >/dev/null
  pass "Removed volume: $OLLAMA_VOLUME"
}

verify_result() {
  log "Verification"

  if docker ps -a --format '{{.Names}}' | grep -Fxq "$OLLAMA_CONTAINER_NAME"; then
    warn "Container still exists: $OLLAMA_CONTAINER_NAME"
  else
    pass "Container not present: $OLLAMA_CONTAINER_NAME"
  fi

  local image_to_check="${DETECTED_IMAGE:-$OLLAMA_IMAGE}"
  if [[ -n "$image_to_check" ]]; then
    if docker image inspect "$image_to_check" >/dev/null 2>&1; then
      warn "Image still present: $image_to_check"
    else
      pass "Image not present: $image_to_check"
    fi
  fi

  if [[ "$REMOVE_MODELS" == "true" ]]; then
    if docker volume ls --format '{{.Name}}' | grep -Fxq "$OLLAMA_VOLUME"; then
      warn "Volume still present: $OLLAMA_VOLUME"
    else
      pass "Volume not present: $OLLAMA_VOLUME"
    fi
  else
    if docker volume ls --format '{{.Name}}' | grep -Fxq "$OLLAMA_VOLUME"; then
      pass "Model library preserved: $OLLAMA_VOLUME"
    else
      warn "Model library volume not found: $OLLAMA_VOLUME"
    fi
  fi
}

print_summary() {
  echo ""
  echo "Ollama uninstall complete."
  if [[ "$REMOVE_MODELS" == "true" ]]; then
    echo "The local model library was removed."
  else
    echo "The local model library was kept."
    echo "You can reuse it later by starting a new Ollama container with volume ${OLLAMA_VOLUME}."
  fi
  echo ""
}

main() {
  parse_args "$@"
  need_cmd docker
  need_cmd python3

  detect_state
  if nothing_to_remove; then
    echo ""
    echo "No local Ollama container, model volume, or explicit image override was found to remove."
    echo ""
    exit 0
  fi
  summarize_model_library
  offer_model_volume_removal
  confirm_uninstall
  confirm_model_volume_removal
  remove_container
  remove_image_if_present
  remove_model_volume_if_requested
  verify_result
  print_summary
}

main "$@"
