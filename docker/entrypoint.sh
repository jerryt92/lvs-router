#!/bin/sh
set -eu

INSTALL_ROOT="${INSTALL_ROOT:-/opt/lvs-router}"
ENV_FILE="$INSTALL_ROOT/lvs-router.env"
START_SCRIPT="$INSTALL_ROOT/bin/start.sh"
STOP_SCRIPT="$INSTALL_ROOT/bin/stop.sh"
LOG_DIR="${ROUTER_LOG_DIR:-$INSTALL_ROOT/logs}"
PID_DIR="${ROUTER_RUN_DIR:-$INSTALL_ROOT/run}/pids"
KEEPALIVED_PID_FILE="$PID_DIR/keepalived.pid"
ROUTER_PID_FILE="$PID_DIR/router-id-server.pid"
TAIL_PID=""

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

is_running_pid_file() {
  pid_file="$1"
  if [ ! -f "$pid_file" ]; then
    return 1
  fi

  pid="$(awk 'NR==1 { print $1 }' "$pid_file" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    return 1
  fi

  kill -0 "$pid" 2>/dev/null
}

stop_runtime() {
  "$STOP_SCRIPT" >/dev/null 2>&1 || true
  if [ -n "$TAIL_PID" ]; then
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
  fi
}

trap 'stop_runtime; exit 0' INT TERM

"$START_SCRIPT"

mkdir -p "$LOG_DIR"
tail -n +1 -f \
  "$LOG_DIR/start.log" \
  "$LOG_DIR/keepalived.log" \
  "$LOG_DIR/router-id-server.log" &
TAIL_PID=$!

while :; do
  if ! is_running_pid_file "$KEEPALIVED_PID_FILE"; then
    echo "keepalived exited unexpectedly" >&2
    stop_runtime
    exit 1
  fi

  if ! is_running_pid_file "$ROUTER_PID_FILE"; then
    echo "router-id-server exited unexpectedly" >&2
    stop_runtime
    exit 1
  fi

  sleep 2
done
