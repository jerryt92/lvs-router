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
IPVS_KEEPALIVED_CONF="${IPVS_KEEPALIVED_CONF:-$INSTALL_ROOT/keepalived/ipvs.conf}"
IPVS_KEEPALIVED_PID_FILE="${IPVS_KEEPALIVED_PID_FILE:-$PID_DIR/keepalived-ipvs.pid}"
IPVS_KEEPALIVED_VRRP_PID_FILE="${IPVS_KEEPALIVED_VRRP_PID_FILE:-$PID_DIR/keepalived-ipvs-vrrp.pid}"
IPVS_KEEPALIVED_CHECKERS_PID_FILE="${IPVS_KEEPALIVED_CHECKERS_PID_FILE:-$PID_DIR/keepalived-ipvs-checkers.pid}"
VS_CONF="${VIRTUAL_SERVER_CONF:-$INSTALL_ROOT/keepalived/virtual_server.conf}"
LB_RS_TOPOLOGY="${LB_RS_TOPOLOGY:-merged}"
FORCE_STOP=0

if [ "${1:-}" = "--force" ]; then
  FORCE_STOP=1
fi

case "$LB_RS_TOPOLOGY" in
  merged|separated)
    ;;
  *)
    echo "invalid LB_RS_TOPOLOGY: $LB_RS_TOPOLOGY (expected merged or separated)" >&2
    exit 1
    ;;
esac

if [ "$LB_RS_TOPOLOGY" = "separated" ] && [ "$FORCE_STOP" -ne 1 ]; then
  exit 0
fi

stop_pid_file() {
  pid_file="$1"
  if [ ! -f "$pid_file" ]; then
    return 0
  fi

  pid="$(awk 'NR==1 { print $1 }' "$pid_file" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
}

stop_pid_file "$IPVS_KEEPALIVED_PID_FILE"
stop_pid_file "$IPVS_KEEPALIVED_VRRP_PID_FILE"
stop_pid_file "$IPVS_KEEPALIVED_CHECKERS_PID_FILE"

matching_pids="$(ps -eo pid=,args= | awk -v conf="$IPVS_KEEPALIVED_CONF" 'index($0, "keepalived") && index($0, conf) { print $1 }')"
for pid in $matching_pids; do
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
done

VIP="$(awk '/^[[:space:]]*virtual_server[[:space:]]+/ { print $2; exit }' "$VS_CONF" 2>/dev/null || true)"
PORT="$(awk '/^[[:space:]]*virtual_server[[:space:]]+/ { print $3; exit }' "$VS_CONF" 2>/dev/null || true)"
if [ -n "$VIP" ] && [ -n "$PORT" ]; then
  ipvsadm -D -t "$VIP:$PORT" 2>/dev/null || true
fi
