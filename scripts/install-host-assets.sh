#!/bin/sh
set -eu

DEFAULT_INSTALL_ROOT="/opt/lvs-router"
INSTALL_ROOT_INPUT="${INSTALL_ROOT_INPUT:-}"
LB_ROLE_INPUT="${LB_ROLE_INPUT:-}"

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

AVAILABLE_LB_ROLES=""
for conf in "$REPO_ROOT"/keepalived/lb*/keepalived.conf; do
  [ -f "$conf" ] || continue

  role_dir="$(basename "$(dirname "$conf")")"
  AVAILABLE_LB_ROLES="$AVAILABLE_LB_ROLES $role_dir"
done

AVAILABLE_LB_ROLES="${AVAILABLE_LB_ROLES# }"

if [ -z "$AVAILABLE_LB_ROLES" ]; then
  echo "No keepalived LB configs found under $REPO_ROOT/keepalived" >&2
  exit 1
fi

DEFAULT_LB_ROLE="lb1"
case " $AVAILABLE_LB_ROLES " in
  *" $DEFAULT_LB_ROLE "*) ;;
  *)
    DEFAULT_LB_ROLE="${AVAILABLE_LB_ROLES%% *}"
    ;;
esac

normalize_lb_role() {
  role_input="$1"

  case "$role_input" in
    [0-9]*)
      candidate_role="lb$role_input"
      ;;
    lb[0-9]*|LB[0-9]*)
      candidate_role="$(printf '%s' "$role_input" | tr '[:upper:]' '[:lower:]')"
      ;;
    *)
      return 1
      ;;
  esac

  case " $AVAILABLE_LB_ROLES " in
    *" $candidate_role "*)
      printf '%s' "$candidate_role"
      ;;
    *)
      return 1
      ;;
  esac
}

print_available_lb_roles() {
  role_index=1

  echo "Available LB roles:" >&2
  for lb_role in $AVAILABLE_LB_ROLES; do
    default_marker=""
    if [ "$lb_role" = "$DEFAULT_LB_ROLE" ]; then
      default_marker=" (default)"
    fi

    printf '  %s) %s%s\n' "$role_index" "$lb_role" "$default_marker" >&2
    role_index=$((role_index + 1))
  done
}

if [ -n "$INSTALL_ROOT_INPUT" ]; then
  INSTALL_ROOT="$INSTALL_ROOT_INPUT"
elif [ -t 0 ]; then
  printf 'Install root [%s]: ' "$DEFAULT_INSTALL_ROOT" >&2
  read -r INSTALL_ROOT
  [ -n "$INSTALL_ROOT" ] || INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
else
  INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
fi

if [ -n "$LB_ROLE_INPUT" ]; then
  if ! LB_ROLE="$(normalize_lb_role "$LB_ROLE_INPUT")"; then
    echo "Invalid LB role: $LB_ROLE_INPUT (available: $AVAILABLE_LB_ROLES)" >&2
    exit 1
  fi
elif [ -t 0 ]; then
  print_available_lb_roles
  while :; do
    printf 'Select LB role [%s]: ' "${DEFAULT_LB_ROLE#lb}" >&2
    read -r LB_ROLE_SELECTED
    [ -n "$LB_ROLE_SELECTED" ] || LB_ROLE_SELECTED="${DEFAULT_LB_ROLE#lb}"

    if LB_ROLE="$(normalize_lb_role "$LB_ROLE_SELECTED")"; then
      break
    fi

    echo "Invalid selection: $LB_ROLE_SELECTED (available: $AVAILABLE_LB_ROLES)" >&2
  done
else
  LB_ROLE="$DEFAULT_LB_ROLE"
fi

BIN_DIR="$INSTALL_ROOT/bin"
KEEPALIVED_DIR="$INSTALL_ROOT/keepalived"
ENV_FILE="$INSTALL_ROOT/lvs-router.env"
RUN_DIR="$INSTALL_ROOT/run"

stop_previous_runtime() {
  STOP_SCRIPT="$BIN_DIR/stop.sh"
  if [ -x "$STOP_SCRIPT" ]; then
    echo "Stopping existing lvs-router runtime under $INSTALL_ROOT"
    "$STOP_SCRIPT" >/dev/null 2>&1 || true
  fi

  if command -v ipvsadm >/dev/null 2>&1; then
    echo "Clearing existing IPVS rules before reinstall"
    ipvsadm -C >/dev/null 2>&1 || true
  fi
}

cleanup_previous_install() {
  case "$INSTALL_ROOT" in
    ""|"/")
      echo "Refusing to remove unsafe install root: $INSTALL_ROOT" >&2
      exit 1
      ;;
  esac

  if [ -e "$INSTALL_ROOT" ]; then
    echo "Removing existing install root: $INSTALL_ROOT"
    rm -rf "$INSTALL_ROOT"
  fi
}

escape_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

ROOT_ESCAPED="$(escape_replacement "$INSTALL_ROOT")"
DEFAULT_ROOT_ESCAPED="$(escape_replacement "$DEFAULT_INSTALL_ROOT")"

stop_previous_runtime
cleanup_previous_install

install -d "$BIN_DIR" "$KEEPALIVED_DIR" "$RUN_DIR"
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
for conf in "$KEEPALIVED_DIR"/lb*/keepalived.conf; do
  [ -f "$conf" ] || continue
  sed -i'' "s|$DEFAULT_ROOT_ESCAPED|$ROOT_ESCAPED|g" "$conf"
done
sed -i'' "s|^KEEPALIVED_CONF=.*$|KEEPALIVED_CONF=$INSTALL_ROOT/keepalived/$LB_ROLE/keepalived.conf|" "$ENV_FILE"

echo "Installed scripts to $BIN_DIR"
echo "Installed keepalived configs to $KEEPALIVED_DIR"
echo "Installed environment file to $ENV_FILE"
echo "Selected LB role: $LB_ROLE"
echo "Prepared runtime directory at $RUN_DIR"
echo "Next: edit $ENV_FILE and run $BIN_DIR/start.sh"
