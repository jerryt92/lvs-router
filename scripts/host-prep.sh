#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
CONF="${KEEPALIVED_CONF:-$INSTALL_ROOT/keepalived/lb1/keepalived.conf}"
DOCROOT="${ROUTER_HTTP_DOCROOT:-$INSTALL_ROOT/run/router-http}"

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
ROUTER_ID="$(awk '/^[[:space:]]*router_id[[:space:]]+/ { print $2; exit }' "$CONF" 2>/dev/null || true)"
[ -n "$ROUTER_ID" ] || ROUTER_ID="unknown"

mkdir -p "$DOCROOT"
printf '%s' "$ROUTER_ID" >"$DOCROOT/router_id"

if [ -z "$VIP" ]; then
  exit 0
fi

# In LVS-DR mode the director must own the VIP locally but never answer ARP for it.
ip addr add "$VIP/32" dev lo 2>/dev/null || true
sysctl -w net.ipv4.conf.all.arp_ignore=1 >/dev/null
sysctl -w net.ipv4.conf.all.arp_announce=2 >/dev/null
sysctl -w net.ipv4.conf.default.arp_ignore=1 >/dev/null
sysctl -w net.ipv4.conf.default.arp_announce=2 >/dev/null
sysctl -w net.ipv4.conf.lo.arp_ignore=1 >/dev/null
sysctl -w net.ipv4.conf.lo.arp_announce=2 >/dev/null
# Expire stale IPVS connections/templates quickly after a real server disappears.
sysctl -w net.ipv4.vs.expire_nodest_conn=1 >/dev/null
sysctl -w net.ipv4.vs.expire_quiescent_template=1 >/dev/null

if [ -n "$IFACE" ]; then
  sysctl -w "net.ipv4.conf.$IFACE.arp_ignore=1" >/dev/null
  sysctl -w "net.ipv4.conf.$IFACE.arp_announce=2" >/dev/null
fi
