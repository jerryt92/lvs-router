#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root." >&2
  exit 1
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
RPM_DIR="${RPM_DIR:-$SCRIPT_DIR/rpms}"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR/project}"
AUTO_ENABLE_SERVICES="${AUTO_ENABLE_SERVICES:-1}"
AUTO_START_SERVICES="${AUTO_START_SERVICES:-0}"

if [ ! -d "$RPM_DIR" ]; then
  echo "RPM directory not found: $RPM_DIR" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Project directory not found: $PROJECT_DIR" >&2
  exit 1
fi

install_local_rpms() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y --disablerepo='*' --nogpgcheck "$RPM_DIR"/*.rpm
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    yum localinstall -y --disablerepo='*' --nogpgcheck "$RPM_DIR"/*.rpm
    return
  fi

  echo "Neither dnf nor yum is available on this host." >&2
  exit 1
}

install_local_rpms
"$PROJECT_DIR/scripts/install-host-assets.sh"

systemctl daemon-reload

if [ "$AUTO_ENABLE_SERVICES" = "1" ]; then
  systemctl enable lvs-router.service
fi

if [ "$AUTO_START_SERVICES" = "1" ]; then
  systemctl start lvs-router.service
fi

echo "Offline dependency installation completed."
echo "Edit the installed lvs-router.env before starting services."
echo "Project files are available at: $PROJECT_DIR"
