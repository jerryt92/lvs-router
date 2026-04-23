#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
CONF="${KEEPALIVED_CONF:-$INSTALL_ROOT/keepalived/lb1/keepalived.conf}"
DOCROOT="${ROUTER_HTTP_DOCROOT:-$INSTALL_ROOT/run/router-http}"

IFACE="$(awk '/^[[:space:]]*interface[[:space:]]+/ { print $2; exit }' "$CONF" 2>/dev/null || true)"
ROUTER_ID="$(awk '/^[[:space:]]*router_id[[:space:]]+/ { print $2; exit }' "$CONF" 2>/dev/null || true)"
[ -n "$ROUTER_ID" ] || ROUTER_ID="unknown"

mkdir -p "$DOCROOT"
printf '%s' "$ROUTER_ID" >"$DOCROOT/router_id"

# Keepalived owns the loopback VIP via static_ipaddress; this script only
# applies host-level LVS-DR sysctls that must exist before traffic arrives.
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
