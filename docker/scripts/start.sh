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
KEEPALIVED_CONF="${KEEPALIVED_CONF:-$INSTALL_ROOT/keepalived/lb1/keepalived.conf}"
START_LOG="${START_LOG:-$LOG_DIR/start.log}"
KEEPALIVED_LOG="${KEEPALIVED_LOG:-$LOG_DIR/keepalived.log}"
ROUTER_ID_LOG="${ROUTER_ID_LOG:-$LOG_DIR/router-id-server.log}"
KEEPALIVED_PID_FILE="$PID_DIR/keepalived.pid"
ROUTER_PID_FILE="$PID_DIR/router-id-server.pid"
LB_RS_TOPOLOGY="${LB_RS_TOPOLOGY:-merged}"

case "$LB_RS_TOPOLOGY" in
  merged|separated)
    ;;
  *)
    echo "invalid LB_RS_TOPOLOGY: $LB_RS_TOPOLOGY (expected merged or separated)" >&2
    exit 1
    ;;
esac

log_line() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$START_LOG"
}

is_running_pid_file() {
  pid_file="$1"
  if [ ! -f "$pid_file" ]; then
    return 1
  fi

  pid="$(awk 'NR==1 { print $1 }' "$pid_file" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    rm -f "$pid_file"
    return 1
  fi

  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  rm -f "$pid_file"
  return 1
}

mkdir -p "$LOG_DIR" "$RUN_DIR" "$PID_DIR"
touch "$START_LOG" "$KEEPALIVED_LOG" "$ROUTER_ID_LOG"

if is_running_pid_file "$KEEPALIVED_PID_FILE"; then
  pid="$(awk 'NR==1 { print $1 }' "$KEEPALIVED_PID_FILE" 2>/dev/null || true)"
  log_line "refusing to start: keepalived already running with pid $pid"
  echo "keepalived already running with pid $pid" >&2
  exit 1
fi

if is_running_pid_file "$ROUTER_PID_FILE"; then
  pid="$(awk 'NR==1 { print $1 }' "$ROUTER_PID_FILE" 2>/dev/null || true)"
  log_line "refusing to start: router-id-server already running with pid $pid"
  echo "router-id-server already running with pid $pid" >&2
  exit 1
fi

KEEPALIVED_BIN="${KEEPALIVED_BIN:-$(command -v keepalived 2>/dev/null || true)}"
if [ -z "$KEEPALIVED_BIN" ]; then
  log_line "keepalived binary not found in PATH"
  echo "keepalived binary not found in PATH" >&2
  exit 1
fi

IPVSADM_BIN="${IPVSADM_BIN:-$(command -v ipvsadm 2>/dev/null || true)}"
if [ -z "$IPVSADM_BIN" ]; then
  log_line "ipvsadm binary not found in PATH"
  echo "ipvsadm binary not found in PATH" >&2
  exit 1
fi

log_line "starting lvs-router"
log_line "running keepalived config check: $KEEPALIVED_BIN -t -f $KEEPALIVED_CONF"
if ! "$KEEPALIVED_BIN" -t -f "$KEEPALIVED_CONF" >>"$KEEPALIVED_LOG" 2>&1; then
  log_line "keepalived config check failed for $KEEPALIVED_CONF"
  echo "keepalived config check failed for $KEEPALIVED_CONF" >&2
  exit 1
fi

"$BIN_DIR/load-ipvs-modules.sh" >>"$START_LOG" 2>&1
"$BIN_DIR/stop-ipvs-keepalived.sh" --force >>"$START_LOG" 2>&1 || true
log_line "clearing stale ipvs rules before keepalived startup"
"$IPVSADM_BIN" -C >>"$START_LOG" 2>&1
"$BIN_DIR/host-prep.sh" >>"$START_LOG" 2>&1

"$BIN_DIR/router-id-server.sh" >>"$ROUTER_ID_LOG" 2>&1 &
router_pid=$!
printf '%s\n' "$router_pid" >"$ROUTER_PID_FILE"
log_line "router-id-server started with pid $router_pid"

"$KEEPALIVED_BIN" -nl -f "$KEEPALIVED_CONF" >>"$KEEPALIVED_LOG" 2>&1 &
keepalived_pid=$!
printf '%s\n' "$keepalived_pid" >"$KEEPALIVED_PID_FILE"
log_line "keepalived started with pid $keepalived_pid using $KEEPALIVED_CONF"

if [ "$LB_RS_TOPOLOGY" = "separated" ]; then
  log_line "LB_RS_TOPOLOGY=separated, starting resident ipvs keepalived instance"
  if ! "$BIN_DIR/start-ipvs-keepalived.sh" >>"$START_LOG" 2>&1; then
    log_line "failed to start resident ipvs keepalived instance"
    rm -f "$ROUTER_PID_FILE"
    rm -f "$KEEPALIVED_PID_FILE"
    kill -9 "$router_pid" 2>/dev/null || true
    kill -9 "$keepalived_pid" 2>/dev/null || true
    echo "failed to start resident ipvs keepalived instance" >&2
    exit 1
  fi
fi

sleep 1

if ! kill -0 "$router_pid" 2>/dev/null; then
  log_line "router-id-server exited unexpectedly during startup"
  rm -f "$ROUTER_PID_FILE"
  rm -f "$KEEPALIVED_PID_FILE"
  kill -9 "$keepalived_pid" 2>/dev/null || true
  echo "router-id-server exited unexpectedly during startup" >&2
  exit 1
fi

if ! kill -0 "$keepalived_pid" 2>/dev/null; then
  log_line "keepalived exited unexpectedly during startup"
  rm -f "$ROUTER_PID_FILE"
  rm -f "$KEEPALIVED_PID_FILE"
  kill -9 "$router_pid" 2>/dev/null || true
  echo "keepalived exited unexpectedly during startup" >&2
  exit 1
fi

log_line "lvs-router started in background"
printf 'router-id-server pid: %s\n' "$router_pid"
printf 'keepalived pid: %s\n' "$keepalived_pid"
