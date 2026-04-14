#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
BUNDLE_NAME="${BUNDLE_NAME:-lvs-router-centos-offline}"
BUNDLE_ROOT="$OUTPUT_DIR/$BUNDLE_NAME"
RPM_DIR="$BUNDLE_ROOT/rpms"
PROJECT_DIR="$BUNDLE_ROOT/project"
PACKAGES="${CENTOS_PACKAGES:-keepalived iproute ipvsadm socat kmod}"
ARCHIVE_PATH="$OUTPUT_DIR/$BUNDLE_NAME.tar.gz"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

download_rpms() {
  if command -v dnf >/dev/null 2>&1 && dnf download --help >/dev/null 2>&1; then
    dnf download --resolve --alldeps --destdir "$RPM_DIR" $PACKAGES
    return
  fi

  if command -v yumdownloader >/dev/null 2>&1; then
    yumdownloader --resolve --destdir="$RPM_DIR" $PACKAGES
    return
  fi

  cat >&2 <<'EOF'
Could not find a usable RPM download tool.

Install one of the following on the online CentOS/RHEL machine, then run this script again:
  - dnf download plugin (command: dnf download)
  - yum-utils / yumdownloader
EOF
  exit 1
}

require_command tar
require_command mkdir
require_command rm
require_command cp

rm -rf "$BUNDLE_ROOT"
mkdir -p "$RPM_DIR" "$PROJECT_DIR"

(cd "$REPO_ROOT" && tar \
  --exclude='./dist' \
  --exclude='./.git' \
  --exclude='./.DS_Store' \
  --exclude='./keepalived/.DS_Store' \
  -cf - .) | (cd "$PROJECT_DIR" && tar -xf -)

download_rpms

cp "$REPO_ROOT/packaging/centos-offline/install-offline-bundle.sh" "$BUNDLE_ROOT/install-offline-bundle.sh"
chmod +x "$BUNDLE_ROOT/install-offline-bundle.sh"

{
  echo "# Requested packages"
  for pkg in $PACKAGES; do
    echo "$pkg"
  done
} >"$BUNDLE_ROOT/requested-packages.txt"

(
  cd "$RPM_DIR"
  ls -1 *.rpm 2>/dev/null | sort
) >"$BUNDLE_ROOT/downloaded-rpms.txt"

(cd "$OUTPUT_DIR" && tar -czf "$ARCHIVE_PATH" "$BUNDLE_NAME")

echo "Offline bundle directory created: $BUNDLE_ROOT"
echo "Offline bundle archive created:   $ARCHIVE_PATH"
echo "Copy the tar.gz file or the whole bundle directory to the offline CentOS host."
