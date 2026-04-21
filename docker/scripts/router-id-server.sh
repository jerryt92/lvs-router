#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PORT="${HEALTHY_HTTP_PORT:-45555}"
HANDLER="${ROUTER_ID_HANDLER:-$INSTALL_ROOT/bin/serve-router-id.sh}"

exec socat TCP-LISTEN:"$PORT",bind=0.0.0.0,reuseaddr,fork EXEC:"$HANDLER"
