#!/bin/sh
set -eu

DEFAULT_INSTALL_ROOT="/opt/lvs-router"
INSTALL_ROOT_INPUT="${INSTALL_ROOT_INPUT:-}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

require_commands() {
  missing=""
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done

  if [ -n "$missing" ]; then
    echo "Missing required commands:$missing" >&2
    exit 1
  fi
}

check_runtime_dependencies() {
  runtime_missing=""

  if ! command -v keepalived >/dev/null 2>&1; then
    runtime_missing="$runtime_missing keepalived"
  fi

  if ! command -v ip >/dev/null 2>&1; then
    runtime_missing="$runtime_missing ip"
  fi

  if ! command -v ipvsadm >/dev/null 2>&1; then
    runtime_missing="$runtime_missing ipvsadm"
  fi

  if ! command -v socat >/dev/null 2>&1; then
    runtime_missing="$runtime_missing socat"
  fi

  if ! command -v modprobe >/dev/null 2>&1; then
    runtime_missing="$runtime_missing modprobe"
  fi

  if [ -n "$runtime_missing" ]; then
    cat >&2 <<EOF
Runtime dependencies are missing:$runtime_missing

Install the missing packages first, then run this installer again.
CentOS / Rocky / AlmaLinux example:
  dnf install -y keepalived iproute ipvsadm socat kmod
EOF
    exit 1
  fi
}

require_commands install cp rm sed mkdir
check_runtime_dependencies

if [ -n "$INSTALL_ROOT_INPUT" ]; then
  INSTALL_ROOT="$INSTALL_ROOT_INPUT"
elif [ -t 0 ]; then
  printf 'Install root [%s]: ' "$DEFAULT_INSTALL_ROOT" >&2
  read -r INSTALL_ROOT
  [ -n "$INSTALL_ROOT" ] || INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
else
  INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
fi

BIN_DIR="$INSTALL_ROOT/bin"
KEEPALIVED_DIR="$INSTALL_ROOT/keepalived"
ENV_FILE="$INSTALL_ROOT/lvs-router.env"
RUN_DIR="$INSTALL_ROOT/run"

cleanup_previous_install() {
  rm -f "$BIN_DIR/ipvs-state.sh"
  rm -f "$BIN_DIR/serve-router-id.sh"
  rm -f "$BIN_DIR/host-prep.sh"
  rm -f "$BIN_DIR/router-id-server.sh"
  rm -f "$BIN_DIR/load-ipvs-modules.sh"
  rm -f "$BIN_DIR/restart.sh"
  rm -f "$BIN_DIR/start.sh"
  rm -f "$BIN_DIR/status.sh"
  rm -f "$BIN_DIR/stop.sh"

  rm -rf "$KEEPALIVED_DIR"
  rm -f "$ENV_FILE"
}

escape_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

ROOT_ESCAPED="$(escape_replacement "$INSTALL_ROOT")"
DEFAULT_ROOT_ESCAPED="$(escape_replacement "$DEFAULT_INSTALL_ROOT")"

cleanup_previous_install

install -d "$BIN_DIR" "$KEEPALIVED_DIR" "$RUN_DIR"
install -m 0755 "$REPO_ROOT/lb/ipvs-state.sh" "$BIN_DIR/ipvs-state.sh"
install -m 0755 "$REPO_ROOT/lb/serve-router-id.sh" "$BIN_DIR/serve-router-id.sh"
install -m 0755 "$REPO_ROOT/scripts/host-prep.sh" "$BIN_DIR/host-prep.sh"
install -m 0755 "$REPO_ROOT/scripts/router-id-server.sh" "$BIN_DIR/router-id-server.sh"
install -m 0755 "$REPO_ROOT/scripts/load-ipvs-modules.sh" "$BIN_DIR/load-ipvs-modules.sh"
install -m 0755 "$REPO_ROOT/scripts/restart.sh" "$BIN_DIR/restart.sh"
install -m 0755 "$REPO_ROOT/scripts/start.sh" "$BIN_DIR/start.sh"
install -m 0755 "$REPO_ROOT/scripts/status.sh" "$BIN_DIR/status.sh"
install -m 0755 "$REPO_ROOT/scripts/stop.sh" "$BIN_DIR/stop.sh"

cp -R "$REPO_ROOT/keepalived/." "$KEEPALIVED_DIR/"
install -m 0644 "$REPO_ROOT/lvs-router.env.example" "$ENV_FILE"

sed -i'' "s|$DEFAULT_ROOT_ESCAPED|$ROOT_ESCAPED|g" "$ENV_FILE"
sed -i'' "s|$DEFAULT_ROOT_ESCAPED|$ROOT_ESCAPED|g" "$KEEPALIVED_DIR/lb1/keepalived.conf"
sed -i'' "s|$DEFAULT_ROOT_ESCAPED|$ROOT_ESCAPED|g" "$KEEPALIVED_DIR/lb2/keepalived.conf"

echo "Installed scripts to $BIN_DIR"
echo "Installed keepalived configs to $KEEPALIVED_DIR"
echo "Installed environment file to $ENV_FILE"
echo "Prepared runtime directory at $RUN_DIR"
echo "Next: edit $ENV_FILE and run $BIN_DIR/start.sh"
