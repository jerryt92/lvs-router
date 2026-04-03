#!/bin/sh
set -eu

DEFAULT_CONF="${KEEPALIVED_CONF:-/etc/keepalived/lb1/keepalived.conf}"
CONF="$DEFAULT_CONF"
has_valid_f=0
prev=""
for arg in "$@"; do
  if [ "$prev" = "-f" ]; then
    if [ -f "$arg" ]; then
      CONF="$arg"
      has_valid_f=1
    fi
    break
  fi
  prev="$arg"
done
if [ "$has_valid_f" -eq 0 ]; then
  CONF="$DEFAULT_CONF"
fi

VIP="$(awk '
  /virtual_ipaddress[[:space:]]*\{/ { in_block=1; next }
  in_block && /\}/ { in_block=0 }
  in_block {
    split($1, parts, "/")
    print parts[1]
    exit
  }
' "$CONF" 2>/dev/null || true)"
IFACE="$(awk '/^[[:space:]]*interface[[:space:]]+/ { print $2; exit }' "$CONF" 2>/dev/null || true)"
ROUTER_ID="$(grep -E '^\s*router_id\s+' "$CONF" 2>/dev/null | head -1 | awk '{print $2}' || true)"
[ -n "$ROUTER_ID" ] || ROUTER_ID="unknown"

PORT="${HEALTHY_HTTP_PORT:-45555}"
DOCROOT="/run/router-http"
mkdir -p "$DOCROOT"
printf '%s' "$ROUTER_ID" >"$DOCROOT/router_id"

if [ -n "$VIP" ]; then
  # Real servers in DR mode must own the VIP locally, but never answer ARP for it.
  ip addr add "$VIP/32" dev lo 2>/dev/null || true
  sysctl -w net.ipv4.conf.all.arp_ignore=1 >/dev/null
  sysctl -w net.ipv4.conf.all.arp_announce=2 >/dev/null
  sysctl -w net.ipv4.conf.default.arp_ignore=1 >/dev/null
  sysctl -w net.ipv4.conf.default.arp_announce=2 >/dev/null
  sysctl -w net.ipv4.conf.lo.arp_ignore=1 >/dev/null
  sysctl -w net.ipv4.conf.lo.arp_announce=2 >/dev/null
  if [ -n "$IFACE" ]; then
    sysctl -w "net.ipv4.conf.$IFACE.arp_ignore=1" >/dev/null
    sysctl -w "net.ipv4.conf.$IFACE.arp_announce=2" >/dev/null
  fi
fi

socat TCP-LISTEN:"$PORT",bind=0.0.0.0,reuseaddr,fork EXEC:"/usr/local/bin/serve-router-id.sh" &
if [ "${1:-}" = "keepalived" ] && [ "$has_valid_f" -eq 0 ]; then
  /usr/local/bin/ipvs-state.sh backup
  exec keepalived -nl -f "$CONF"
fi
exec "$@"
