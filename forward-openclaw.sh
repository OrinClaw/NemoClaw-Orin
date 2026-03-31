#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

SANDBOX_NAME=""
ACTION="ensure"   # ensure | status | stop
BIND_SPEC="${BIND_SPEC:-127.0.0.1:18789}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-15}"

BIND_HOST=""
FORWARD_PORT=""

usage() {
  cat <<'EOF'
Usage:
  ./forward-openclaw.sh <sandbox-name>
  ./forward-openclaw.sh <sandbox-name> --status
  ./forward-openclaw.sh <sandbox-name> --stop
  ./forward-openclaw.sh <sandbox-name> --bind 127.0.0.1:18789
  ./forward-openclaw.sh <sandbox-name> --bind 0.0.0.0:18789

Flags:
  --status
  --stop
  --bind <bind:port>          Bind address and port (default: 127.0.0.1:18789)
  --timeout <seconds>         Listener verification timeout (default: 15)
  --quiet
  --verbose
  --debug
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        ACTION="status"
        shift
        ;;
      --stop)
        ACTION="stop"
        shift
        ;;
      --bind)
        [[ $# -ge 2 ]] || die "Missing value for --bind"
        BIND_SPEC="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "Missing value for --timeout"
        VERIFY_TIMEOUT="$2"
        shift 2
        ;;
      --quiet)
        QUIET="true"
        shift
        ;;
      --verbose)
        VERBOSE="true"
        shift
        ;;
      --debug)
        DEBUG="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -z "$SANDBOX_NAME" ]]; then
          SANDBOX_NAME="$1"
        else
          die "Unexpected extra argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$SANDBOX_NAME" ]] || die "Usage: $0 <sandbox-name>"
}

parse_bind_spec() {
  if [[ "$BIND_SPEC" == *:* ]]; then
    BIND_HOST="${BIND_SPEC%:*}"
    FORWARD_PORT="${BIND_SPEC##*:}"
  else
    BIND_HOST="127.0.0.1"
    FORWARD_PORT="$BIND_SPEC"
    BIND_SPEC="${BIND_HOST}:${FORWARD_PORT}"
  fi

  [[ -n "$BIND_HOST" ]] || die "Invalid bind host in --bind '$BIND_SPEC'"
  [[ "$FORWARD_PORT" =~ ^[0-9]+$ ]] || die "Invalid port in --bind '$BIND_SPEC'"
  (( FORWARD_PORT >= 1 && FORWARD_PORT <= 65535 )) || die "Port out of range in --bind '$BIND_SPEC'"
}

listener_matches_bind() {
  local lines
  lines="$(ss -ltnH "sport = :${FORWARD_PORT}" 2>/dev/null || true)"
  [[ -n "$lines" ]] || return 1

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local local_addr
    local_addr="$(awk '{print $4}' <<<"$line")"

    case "$BIND_HOST" in
      127.0.0.1)
        [[ "$local_addr" == 127.0.0.1:* || "$local_addr" == '[::1]:'* || "$local_addr" == 0.0.0.0:* || "$local_addr" == '*:'* || "$local_addr" == '[::]:'* ]] && return 0
        ;;
      0.0.0.0)
        [[ "$local_addr" == 0.0.0.0:* || "$local_addr" == '*:'* || "$local_addr" == '[::]:'* ]] && return 0
        ;;
      *)
        [[ "$local_addr" == "${BIND_HOST}:"* || "$local_addr" == "[${BIND_HOST}]:"* || "$local_addr" == 0.0.0.0:* || "$local_addr" == '*:'* || "$local_addr" == '[::]:'* ]] && return 0
        ;;
    esac
  done <<<"$lines"

  return 1
}

forward_list_row() {
  openshell forward list 2>/dev/null | \
    sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | \
    awk -v sb="$SANDBOX_NAME" -v bind="$BIND_HOST" -v port="$FORWARD_PORT" '
      NR > 1 && $1 == sb && $2 == bind && $3 == port { print; exit }
    '
}

print_access_url() {
  echo ""
  echo "Access:"
  if [[ "$BIND_HOST" == "0.0.0.0" ]]; then
    echo "  http://127.0.0.1:${FORWARD_PORT}/"
    echo "  http://0.0.0.0:${FORWARD_PORT}/"
  else
    echo "  http://${BIND_HOST}:${FORWARD_PORT}/"
  fi
}

ensure_forward() {
  ui_step "Checking existing OpenClaw browser forward"
  if listener_matches_bind; then
    ui_info "✓ OpenClaw browser forward is already active"
    print_access_url
    return 0
  fi

  local row
  row="$(forward_list_row || true)"
  if [[ -n "$row" && ( "$row" == *"dead"* || "$row" == *"stopped"* ) ]]; then
    ui_step "Stopping stale OpenShell forward record"
    openshell forward stop "$FORWARD_PORT" "$SANDBOX_NAME" >/dev/null 2>&1 || true
  fi

  ui_step "Starting browser forward for sandbox '${SANDBOX_NAME}'"
  openshell forward start "$BIND_SPEC" "$SANDBOX_NAME" --background >/dev/null

  ui_step "Verifying localhost listener on ${BIND_SPEC}"
  local elapsed=0
  while [[ "$elapsed" -lt "$VERIFY_TIMEOUT" ]]; do
    if listener_matches_bind; then
      ui_info "✓ OpenClaw browser forward is active"
      print_access_url
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  ui_warn "Forward command returned, but no matching host listener was detected."
  ui_warn "Check: openshell forward list"
  return 1
}

status_forward() {
  ui_step "Checking OpenClaw browser forward status"

  local row status
  row="$(forward_list_row || true)"
  status=""
  if [[ -n "$row" ]]; then
    status="$(awk '{print tolower($5)}' <<<"$row")"
  fi

  if listener_matches_bind; then
    ui_info "✓ Host listener present on ${BIND_SPEC}"
    if [[ -n "$status" ]]; then
      ui_info "OpenShell forward status: ${status}"
    fi
    print_access_url
    return 0
  fi

  ui_warn "No matching host listener detected on ${BIND_SPEC}"
  if [[ -n "$status" ]]; then
    ui_warn "OpenShell forward status: ${status}"
  fi
  return 1
}

stop_forward() {
  ui_step "Stopping OpenClaw browser forward for sandbox '${SANDBOX_NAME}'"
  openshell forward stop "$FORWARD_PORT" "$SANDBOX_NAME" >/dev/null 2>&1 || true

  sleep 1
  if listener_matches_bind; then
    ui_warn "A listener is still present on ${BIND_SPEC}"
    ui_warn "It may belong to a non-OpenShell process."
    return 1
  fi

  ui_info "✓ OpenClaw browser forward is stopped"
  return 0
}

main() {
  parse_args "$@"
  parse_bind_spec

  need_cmd openshell
  need_cmd ss

  case "$ACTION" in
    ensure) ensure_forward ;;
    status) status_forward ;;
    stop) stop_forward ;;
    *) die "Unsupported action: $ACTION" ;;
  esac
}

main "$@"
