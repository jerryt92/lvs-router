#!/bin/sh
set -eu

VS_CONF="${VIRTUAL_SERVER_CONF:-/etc/keepalived/virtual_server.conf}"
POLL_INTERVAL="${VIRTUAL_SERVER_POLL_INTERVAL:-2}"
last_checksum=""

checksum_of() {
  if [ -f "$VS_CONF" ]; then
    cksum "$VS_CONF" 2>/dev/null || true
  else
    printf '%s\n' "missing"
  fi
}

while true; do
  current_checksum="$(checksum_of)"
  if [ "$current_checksum" != "$last_checksum" ]; then
    if /usr/local/bin/ipvs-state.sh sync; then
      last_checksum="$current_checksum"
    fi
  fi
  sleep "$POLL_INTERVAL"
done
