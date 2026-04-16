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

RUN_DIR="${ROUTER_RUN_DIR:-$INSTALL_ROOT/run}"
PID_DIR="$RUN_DIR/pids"
LOG_DIR="${ROUTER_LOG_DIR:-$INSTALL_ROOT/logs}"
KEEPALIVED_LOG="${KEEPALIVED_LOG:-$LOG_DIR/keepalived.log}"
IPVS_KEEPALIVED_CONF="${IPVS_KEEPALIVED_CONF:-$INSTALL_ROOT/keepalived/ipvs.conf}"
IPVS_KEEPALIVED_PID_FILE="${IPVS_KEEPALIVED_PID_FILE:-$PID_DIR/keepalived-ipvs.pid}"
IPVS_KEEPALIVED_VRRP_PID_FILE="${IPVS_KEEPALIVED_VRRP_PID_FILE:-$PID_DIR/keepalived-ipvs-vrrp.pid}"
IPVS_KEEPALIVED_CHECKERS_PID_FILE="${IPVS_KEEPALIVED_CHECKERS_PID_FILE:-$PID_DIR/keepalived-ipvs-checkers.pid}"
KEEPALIVED_BIN="${KEEPALIVED_BIN:-$(command -v keepalived 2>/dev/null || true)}"

if [ -z "$KEEPALIVED_BIN" ]; then
  echo "keepalived binary not found in PATH" >&2
  exit 1
fi

mkdir -p "$PID_DIR" "$LOG_DIR"
touch "$KEEPALIVED_LOG"

if [ -f "$IPVS_KEEPALIVED_PID_FILE" ]; then
  existing_pid="$(awk 'NR==1 { print $1 }' "$IPVS_KEEPALIVED_PID_FILE" 2>/dev/null || true)"
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    exit 0
  fi
  rm -f "$IPVS_KEEPALIVED_PID_FILE"
fi

"$KEEPALIVED_BIN" -t -f "$IPVS_KEEPALIVED_CONF" >>"$KEEPALIVED_LOG" 2>&1

"$KEEPALIVED_BIN" \
  -nl \
  -f "$IPVS_KEEPALIVED_CONF" \
  -p "$IPVS_KEEPALIVED_PID_FILE" \
  -r "$IPVS_KEEPALIVED_VRRP_PID_FILE" \
  -c "$IPVS_KEEPALIVED_CHECKERS_PID_FILE" \
  >>"$KEEPALIVED_LOG" 2>&1 &

sleep 1

started_pid="$(awk 'NR==1 { print $1 }' "$IPVS_KEEPALIVED_PID_FILE" 2>/dev/null || true)"
if [ -z "$started_pid" ] || ! kill -0 "$started_pid" 2>/dev/null; then
  echo "failed to start ipvs keepalived instance" >&2
  exit 1
fi
