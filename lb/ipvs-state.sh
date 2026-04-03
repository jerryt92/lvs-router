#!/bin/sh
set -eu

DEFAULT_CONF="${KEEPALIVED_CONF:-/etc/keepalived/lb1/keepalived.conf}"
CONF="${KEEPALIVED_CONF_PATH:-$DEFAULT_CONF}"
VS_CONF="${VIRTUAL_SERVER_CONF:-/etc/keepalived/virtual_server.conf}"
STATE="${1:-backup}"
STATE_FILE="${IPVS_STATE_FILE:-/run/ipvs-state/current_service}"

VIP="$(awk '/^[[:space:]]*virtual_server[[:space:]]+/ { print $2; exit }' "$VS_CONF" 2>/dev/null || true)"
PORT="$(awk '/^[[:space:]]*virtual_server[[:space:]]+/ { print $3; exit }' "$VS_CONF" 2>/dev/null || true)"
ALGO="$(awk '/^[[:space:]]*lb_algo[[:space:]]+/ { print $2; exit }' "$VS_CONF" 2>/dev/null || true)"
KIND="$(awk '/^[[:space:]]*lb_kind[[:space:]]+/ { print $2; exit }' "$VS_CONF" 2>/dev/null || true)"
RS_LIST="$(
  awk '
    function delta_depth(line,    tmp, opens, closes) {
      tmp = line
      opens = gsub(/\{/, "{", tmp)
      tmp = line
      closes = gsub(/\}/, "}", tmp)
      return opens - closes
    }
    /^[[:space:]]*real_server[[:space:]]+/ {
      ip = $2
      port = $3
      weight = 1
      in_rs = 1
      depth = 1
      next
    }
    in_rs {
      if ($1 == "weight") {
        weight = $2
      }
      depth += delta_depth($0)
      if (depth <= 0) {
        print ip ":" port ":" weight
        in_rs = 0
      }
    }
  ' "$VS_CONF" 2>/dev/null || true
)"

[ -n "$VIP" ] || exit 0
[ -n "$PORT" ] || exit 0
[ -n "$ALGO" ] || ALGO="rr"

case "$KIND" in
  DR|"")
    FORWARD_MODE="-g"
    ;;
  NAT)
    FORWARD_MODE="-m"
    ;;
  TUN)
    FORWARD_MODE="-i"
    ;;
  *)
    echo "Unsupported lb_kind: $KIND" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$STATE_FILE")"

current_vrrp_vip() {
  awk '
    /virtual_ipaddress[[:space:]]*\{/ { in_block=1; next }
    in_block && /\}/ { in_block=0 }
    in_block {
      split($1, parts, "/")
      print parts[1]
      exit
    }
  ' "$CONF" 2>/dev/null || true
}

current_vrrp_iface() {
  awk '/^[[:space:]]*interface[[:space:]]+/ { print $2; exit }' "$CONF" 2>/dev/null || true
}

list_current_rs() {
  ipvsadm -Ln --exact -t "$VIP:$PORT" 2>/dev/null | awk '/^[[:space:]]*->/ { print $2 }'
}

has_desired_rs() {
  target="$1"
  printf '%s\n' "$RS_LIST" | awk -F: -v target="$target" 'NF >= 3 && ($1 ":" $2) == target { found=1 } END { exit found ? 0 : 1 }'
}

sync_real_servers() {
  printf '%s\n' "$RS_LIST" | while IFS=: read -r rs_ip rs_port rs_weight; do
    [ -n "${rs_ip:-}" ] || continue
    [ -n "${rs_port:-}" ] || continue
    [ -n "${rs_weight:-}" ] || rs_weight=1
    rs="$rs_ip:$rs_port"
    if ipvsadm -Ln --exact -t "$VIP:$PORT" 2>/dev/null | awk -v target="$rs" '/^[[:space:]]*->/ && $2 == target { found=1 } END { exit found ? 0 : 1 }'; then
      ipvsadm -e -t "$VIP:$PORT" -r "$rs" "$FORWARD_MODE" -w "$rs_weight"
    else
      ipvsadm -a -t "$VIP:$PORT" -r "$rs" "$FORWARD_MODE" -w "$rs_weight"
    fi
  done

  list_current_rs | while IFS= read -r current_rs; do
    [ -n "${current_rs:-}" ] || continue
    if ! has_desired_rs "$current_rs"; then
      ipvsadm -d -t "$VIP:$PORT" -r "$current_rs"
    fi
  done
}

ensure_service() {
  ipvsadm -E -t "$VIP:$PORT" -s "$ALGO" >/dev/null 2>&1 || ipvsadm -A -t "$VIP:$PORT" -s "$ALGO"
}

remember_service() {
  printf '%s %s\n' "$VIP" "$PORT" >"$STATE_FILE"
}

cleanup_previous_service() {
  if [ -f "$STATE_FILE" ]; then
    prev_vip="$(awk 'NR==1 { print $1 }' "$STATE_FILE" 2>/dev/null || true)"
    prev_port="$(awk 'NR==1 { print $2 }' "$STATE_FILE" 2>/dev/null || true)"
    if [ -n "$prev_vip" ] && [ -n "$prev_port" ] && { [ "$prev_vip" != "$VIP" ] || [ "$prev_port" != "$PORT" ]; }; then
      ipvsadm -D -t "$prev_vip:$prev_port" 2>/dev/null || true
    fi
  fi
}

delete_service() {
  ipvsadm -D -t "$VIP:$PORT" 2>/dev/null || true
  rm -f "$STATE_FILE"
}

add_service() {
  cleanup_previous_service
  ensure_service
  sync_real_servers
  remember_service
}

sync_state() {
  local_vip="$(current_vrrp_vip)"
  local_iface="$(current_vrrp_iface)"

  if [ -n "$local_vip" ] && [ -n "$local_iface" ] && ip -o addr show dev "$local_iface" | awk '{ print $4 }' | grep -qx "$local_vip/32"; then
    add_service
  else
    cleanup_previous_service
    delete_service
  fi
}

case "$STATE" in
  master)
    add_service
    ;;
  backup|fault|stop)
    cleanup_previous_service
    delete_service
    ;;
  sync)
    sync_state
    ;;
  *)
    echo "Unknown state: $STATE" >&2
    exit 1
    ;;
esac
