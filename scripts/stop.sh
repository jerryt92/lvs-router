#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$INSTALL_ROOT/bin"
LOG_DIR="${ROUTER_LOG_DIR:-$INSTALL_ROOT/logs}"
RUN_DIR="${ROUTER_RUN_DIR:-$INSTALL_ROOT/run}"
PID_DIR="$RUN_DIR/pids"
START_LOG="${START_LOG:-$LOG_DIR/start.log}"
STATE_FILE="${IPVS_STATE_FILE:-$INSTALL_ROOT/run/ipvs-state/current_service}"
KEEPALIVED_PID_FILE="$PID_DIR/keepalived.pid"
ROUTER_PID_FILE="$PID_DIR/router-id-server.pid"

mkdir -p "$LOG_DIR"
touch "$START_LOG"

log_line() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$START_LOG"
}

stop_pid_file() {
  pid_file="$1"
  process_name="$2"

  if [ ! -f "$pid_file" ]; then
    log_line "$process_name pid file not found: $pid_file"
    return 0
  fi

  pid="$(awk 'NR==1 { print $1 }' "$pid_file" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    log_line "$process_name pid file empty, removing: $pid_file"
    rm -f "$pid_file"
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    log_line "stopping $process_name with pid $pid"
    kill -9 "$pid" 2>/dev/null || true
  else
    log_line "$process_name pid $pid is not running"
  fi

  rm -f "$pid_file"
}

log_line "running local stop sequence"
stop_pid_file "$KEEPALIVED_PID_FILE" "keepalived"
stop_pid_file "$ROUTER_PID_FILE" "router-id-server"
"$BIN_DIR/ipvs-state.sh" stop >>"$START_LOG" 2>&1 || true

if [ -f "$STATE_FILE" ]; then
  rm -f "$STATE_FILE"
fi

log_line "local stop sequence finished"
