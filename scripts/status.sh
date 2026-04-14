#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${ROUTER_LOG_DIR:-$INSTALL_ROOT/logs}"
RUN_DIR="${ROUTER_RUN_DIR:-$INSTALL_ROOT/run}"
PID_DIR="$RUN_DIR/pids"
STATE_FILE="${IPVS_STATE_FILE:-$INSTALL_ROOT/run/ipvs-state/current_service}"
KEEPALIVED_PID_FILE="$PID_DIR/keepalived.pid"
ROUTER_PID_FILE="$PID_DIR/router-id-server.pid"

print_process_status() {
  pid_file="$1"
  process_name="$2"

  if [ ! -f "$pid_file" ]; then
    printf '%s: not running (pid file missing: %s)\n' "$process_name" "$pid_file"
    return
  fi

  pid="$(awk 'NR==1 { print $1 }' "$pid_file" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    printf '%s: unknown (pid file empty: %s)\n' "$process_name" "$pid_file"
    return
  fi

  if kill -0 "$pid" 2>/dev/null; then
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [ -n "$cmd" ]; then
      printf '%s: running (pid %s) %s\n' "$process_name" "$pid" "$cmd"
    else
      printf '%s: running (pid %s)\n' "$process_name" "$pid"
    fi
  else
    printf '%s: stale pid file (pid %s not running)\n' "$process_name" "$pid"
  fi
}

echo "lvs-router status"
echo
print_process_status "$KEEPALIVED_PID_FILE" "keepalived"
print_process_status "$ROUTER_PID_FILE" "router-id-server"
echo

echo "pid files:"
echo "  $KEEPALIVED_PID_FILE"
echo "  $ROUTER_PID_FILE"
echo

echo "logs:"
echo "  ${START_LOG:-$LOG_DIR/start.log}"
echo "  ${KEEPALIVED_LOG:-$LOG_DIR/keepalived.log}"
echo "  ${ROUTER_ID_LOG:-$LOG_DIR/router-id-server.log}"
echo

if [ -f "$STATE_FILE" ]; then
  printf 'ipvs state file: %s\n' "$STATE_FILE"
  awk '{ print "  " $0 }' "$STATE_FILE"
else
  printf 'ipvs state file: not present (%s)\n' "$STATE_FILE"
fi
echo

if command -v ipvsadm >/dev/null 2>&1; then
  echo "ipvsadm -Ln:"
  ipvsadm -Ln || true
else
  echo "ipvsadm not found in PATH"
fi
