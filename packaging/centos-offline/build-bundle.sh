#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
BUNDLE_NAME="${BUNDLE_NAME:-lvs-router-centos-offline}"
BUNDLE_ROOT=""
RPM_DIR="$BUNDLE_ROOT"
PACKAGES="${CENTOS_PACKAGES:-keepalived iproute ipvsadm socat kmod}"
ARCHIVE_PATH="$OUTPUT_DIR/$BUNDLE_NAME.tar.gz"
STAGING_DIR=""
TOTAL_STEPS=4
CURRENT_STEP=0

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

progress_step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf '\n[%s/%s] %s\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
}

progress_info() {
  printf '  - %s\n' "$1"
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
require_command mktemp
require_command mv

cleanup() {
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
}

trap cleanup EXIT

progress_step "Preparing bundle workspace"
progress_info "Bundle name: $BUNDLE_NAME"
progress_info "Output directory: $OUTPUT_DIR"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lvs-router-centos-offline.XXXXXX")"
BUNDLE_ROOT="$STAGING_DIR/$BUNDLE_NAME"
RPM_DIR="$BUNDLE_ROOT"

rm -rf "$OUTPUT_DIR/$BUNDLE_NAME"
mkdir -p "$RPM_DIR"

progress_step "Downloading RPM dependencies"
progress_info "Requested packages: $PACKAGES"
download_rpms

progress_step "Writing package manifests"
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

progress_step "Moving bundle to output directory"
mkdir -p "$OUTPUT_DIR"
rm -f "$ARCHIVE_PATH"
mv "$BUNDLE_ROOT" "$OUTPUT_DIR/$BUNDLE_NAME"

progress_step "Creating compressed archive"
(cd "$OUTPUT_DIR" && tar -czf "$ARCHIVE_PATH" "$BUNDLE_NAME")

printf '\nBuild completed successfully.\n'
echo "Offline bundle directory created: $OUTPUT_DIR/$BUNDLE_NAME"
echo "Offline bundle archive created:   $ARCHIVE_PATH"
echo "Copy the tar.gz file or the whole bundle directory to the offline CentOS host."
