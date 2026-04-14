#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$INSTALL_ROOT/bin"

"$BIN_DIR/stop.sh"
sleep 1
"$BIN_DIR/start.sh"
