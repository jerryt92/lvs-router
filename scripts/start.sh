#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$INSTALL_ROOT/bin"
LOG_DIR="${ROUTER_LOG_DIR:-$INSTALL_ROOT/logs}"
RUN_DIR="${ROUTER_RUN_DIR:-$INSTALL_ROOT/run}"
KEEPALIVED_CONF="${KEEPALIVED_CONF:-$INSTALL_ROOT/keepalived/lb1/keepalived.conf}"
START_LOG="${START_LOG:-$LOG_DIR/start.log}"
KEEPALIVED_LOG="${KEEPALIVED_LOG:-$LOG_DIR/keepalived.log}"
ROUTER_ID_LOG="${ROUTER_ID_LOG:-$LOG_DIR/router-id-server.log}"

router_pid=""
keepalived_pid=""

log_line() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$START_LOG"
}

terminate() {
  log_line "received stop signal, stopping lvs-router components"
  if [ -n "$keepalived_pid" ]; then
    kill "$keepalived_pid" 2>/dev/null || true
  fi
  if [ -n "$router_pid" ]; then
    kill "$router_pid" 2>/dev/null || true
  fi
  wait "${keepalived_pid:-}" 2>/dev/null || true
  wait "${router_pid:-}" 2>/dev/null || true
  exit 0
}

mkdir -p "$LOG_DIR" "$RUN_DIR" "$RUN_DIR/ipvs-state"
touch "$START_LOG" "$KEEPALIVED_LOG" "$ROUTER_ID_LOG"

trap terminate INT TERM HUP

log_line "starting lvs-router"
"$BIN_DIR/load-ipvs-modules.sh" >>"$START_LOG" 2>&1
"$BIN_DIR/host-prep.sh" >>"$START_LOG" 2>&1
"$BIN_DIR/ipvs-state.sh" backup >>"$START_LOG" 2>&1

"$BIN_DIR/router-id-server.sh" >>"$ROUTER_ID_LOG" 2>&1 &
router_pid=$!
log_line "router-id-server started with pid $router_pid"

/usr/sbin/keepalived -nl -f "$KEEPALIVED_CONF" >>"$KEEPALIVED_LOG" 2>&1 &
keepalived_pid=$!
log_line "keepalived started with pid $keepalived_pid using $KEEPALIVED_CONF"

wait "$keepalived_pid"
keepalived_status=$?
log_line "keepalived exited with status $keepalived_status"

if [ -n "$router_pid" ]; then
  kill "$router_pid" 2>/dev/null || true
  wait "$router_pid" 2>/dev/null || true
fi

exit "$keepalived_status"
