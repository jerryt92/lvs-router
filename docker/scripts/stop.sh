#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$INSTALL_ROOT/lvs-router.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

BIN_DIR="$INSTALL_ROOT/bin"
LOG_DIR="${ROUTER_LOG_DIR:-$INSTALL_ROOT/logs}"
RUN_DIR="${ROUTER_RUN_DIR:-$INSTALL_ROOT/run}"
PID_DIR="$RUN_DIR/pids"
START_LOG="${START_LOG:-$LOG_DIR/start.log}"
KEEPALIVED_PID_FILE="$PID_DIR/keepalived.pid"
ROUTER_PID_FILE="$PID_DIR/router-id-server.pid"
KEEPALIVED_RUNTIME_PID="${KEEPALIVED_RUNTIME_PID:-/run/keepalived.pid}"
KEEPALIVED_CONF="${KEEPALIVED_CONF:-$INSTALL_ROOT/keepalived/lb1/keepalived.conf}"

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

stop_matching_processes() {
  pattern="$1"
  process_name="$2"

  pids="$(ps -eo pid=,args= | awk -v pattern="$pattern" 'index($0, pattern) { print $1 }')"
  if [ -z "$pids" ]; then
    log_line "no matching $process_name processes found for pattern: $pattern"
    return 0
  fi

  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      log_line "stopping $process_name residual process pid $pid"
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
}

log_line "running local stop sequence"
"$BIN_DIR/stop-ipvs-keepalived.sh" --force >>"$START_LOG" 2>&1 || true
stop_pid_file "$KEEPALIVED_PID_FILE" "keepalived"
stop_pid_file "$ROUTER_PID_FILE" "router-id-server"
stop_matching_processes "keepalived -nl -f $KEEPALIVED_CONF" "keepalived"
stop_matching_processes "socat TCP-LISTEN:" "router-id-server"

if [ -f "$KEEPALIVED_RUNTIME_PID" ]; then
  runtime_pid="$(awk 'NR==1 { print $1 }' "$KEEPALIVED_RUNTIME_PID" 2>/dev/null || true)"
  if [ -n "$runtime_pid" ] && kill -0 "$runtime_pid" 2>/dev/null; then
    log_line "stopping keepalived runtime pid $runtime_pid from $KEEPALIVED_RUNTIME_PID"
    kill -9 "$runtime_pid" 2>/dev/null || true
  fi
  rm -f "$KEEPALIVED_RUNTIME_PID"
fi

log_line "local stop sequence finished"
