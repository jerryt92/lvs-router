#!/bin/sh
set -eu

DEFAULT_INSTALL_ROOT="/opt/lvs-router"
INSTALL_ROOT_INPUT="${INSTALL_ROOT_INPUT:-}"
SYSTEMD_LINK_DIR="${SYSTEMD_LINK_DIR:-/etc/systemd/system}"

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

  if ! command -v systemctl >/dev/null 2>&1; then
    runtime_missing="$runtime_missing systemctl"
  fi

  if [ -n "$runtime_missing" ]; then
    cat >&2 <<EOF
Runtime dependencies are missing:$runtime_missing

Install the missing packages first, then run this installer again.
CentOS / Rocky / AlmaLinux example:
  dnf install -y keepalived iproute ipvsadm socat kmod systemd
EOF
    exit 1
  fi
}

require_commands install cp rm sed ln mkdir
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
SYSTEMD_SRC_DIR="$INSTALL_ROOT/systemd"
ENV_FILE="$INSTALL_ROOT/lvs-router.env"
RUN_DIR="$INSTALL_ROOT/run"

escape_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

ROOT_ESCAPED="$(escape_replacement "$INSTALL_ROOT")"

install -d "$BIN_DIR" "$KEEPALIVED_DIR" "$SYSTEMD_SRC_DIR" "$RUN_DIR" "$SYSTEMD_LINK_DIR"
install -m 0755 "$REPO_ROOT/lb/ipvs-state.sh" "$BIN_DIR/ipvs-state.sh"
install -m 0755 "$REPO_ROOT/lb/serve-router-id.sh" "$BIN_DIR/serve-router-id.sh"
install -m 0755 "$REPO_ROOT/scripts/host-prep.sh" "$BIN_DIR/host-prep.sh"
install -m 0755 "$REPO_ROOT/scripts/router-id-server.sh" "$BIN_DIR/router-id-server.sh"
install -m 0755 "$REPO_ROOT/scripts/load-ipvs-modules.sh" "$BIN_DIR/load-ipvs-modules.sh"
install -m 0755 "$REPO_ROOT/scripts/start.sh" "$BIN_DIR/start.sh"
install -m 0755 "$REPO_ROOT/scripts/stop.sh" "$BIN_DIR/stop.sh"

cp -R "$REPO_ROOT/keepalived/." "$KEEPALIVED_DIR/"
install -m 0644 "$REPO_ROOT/lvs-router.env.example" "$ENV_FILE"
install -m 0644 "$REPO_ROOT/systemd/lvs-router.service" "$SYSTEMD_SRC_DIR/lvs-router.service"

sed -i'' "s|/lvs-router|$ROOT_ESCAPED|g" "$ENV_FILE"
sed -i'' "s|/lvs-router|$ROOT_ESCAPED|g" "$SYSTEMD_SRC_DIR/lvs-router.service"
sed -i'' "s|/lvs-router|$ROOT_ESCAPED|g" "$KEEPALIVED_DIR/lb1/keepalived.conf"
sed -i'' "s|/lvs-router|$ROOT_ESCAPED|g" "$KEEPALIVED_DIR/lb2/keepalived.conf"

rm -f "$SYSTEMD_LINK_DIR/lvs-router-keepalived.service"
rm -f "$SYSTEMD_LINK_DIR/lvs-router-router-id.service"
rm -f "$SYSTEMD_LINK_DIR/lvs-router-ipvs-modules.service"
ln -sfn "$SYSTEMD_SRC_DIR/lvs-router.service" "$SYSTEMD_LINK_DIR/lvs-router.service"

echo "Installed scripts to $BIN_DIR"
echo "Installed keepalived configs to $KEEPALIVED_DIR"
echo "Installed systemd unit sources to $SYSTEMD_SRC_DIR"
echo "Linked systemd units into $SYSTEMD_LINK_DIR"
echo "Installed environment file to $ENV_FILE"
echo "Prepared runtime directory at $RUN_DIR"
echo "Next: edit $ENV_FILE and run systemctl daemon-reload"
