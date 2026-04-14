#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$INSTALL_ROOT/bin"
LOG_DIR="${ROUTER_LOG_DIR:-$INSTALL_ROOT/logs}"
START_LOG="${START_LOG:-$LOG_DIR/start.log}"
SERVICE_NAME="${SERVICE_NAME:-lvs-router.service}"
STATE_FILE="${IPVS_STATE_FILE:-$INSTALL_ROOT/run/ipvs-state/current_service}"

mkdir -p "$LOG_DIR"
touch "$START_LOG"

log_line() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$START_LOG"
}

if [ "${1:-}" = "--systemctl" ]; then
  log_line "stopping service via systemctl: $SERVICE_NAME"
  exec systemctl stop "$SERVICE_NAME"
fi

log_line "running local stop sequence"
"$BIN_DIR/ipvs-state.sh" stop >>"$START_LOG" 2>&1 || true

if [ -f "$STATE_FILE" ]; then
  rm -f "$STATE_FILE"
fi

log_line "local stop sequence finished"
