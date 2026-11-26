#!/bin/bash
# restore-host.sh — Undo the host changes made by configure-host.sh.
#
# Run this as a regular user (not via sudo); privileged steps use sudo
# internally, matching configure-host.sh. It is safe to run more than once:
# every step is skipped if the change is not present.
#
# Usage:
#   restore-host.sh [options]
#
# By default it reverses, in order:
# 1. The "127.0.0.1 candlepin" entry added to /etc/hosts
# 2. The Candlepin CA certificate installed into /etc/rhsm/ca and the
#    system trust store (anchor symlink + update-ca-trust)
# 3. The subscription-manager server/repo configuration (restore previous
#    values saved by configure-host.sh)
# 4. The imported test RPM repository GPG key
# 5. The default product certificate created by configure-host.sh (if any;
#    a pre-existing certificate, e.g. on RHEL, is kept)
#
# Each step can be skipped with its --keep-* option (see --help).

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults — every step runs unless its --keep-* option is given.
# ---------------------------------------------------------------------------
RESTORE_ETC_HOSTS=1
RESTORE_CA_CERT=1
RESTORE_SUBMAN=1
RESTORE_GPG_KEY=1
RESTORE_PRODUCT_CERT=1

usage() {
  cat <<EOF
Undo the host changes made by configure-host.sh.

Usage: $(basename "$0") [options]

Options:
  --keep-etc-hosts     Do not remove the "127.0.0.1 candlepin" entry from
                       /etc/hosts.
  --keep-ca-cert       Do not remove the Candlepin CA certificate from
                       /etc/rhsm/ca and the system trust store.
  --keep-subman        Do not restore the subscription-manager configuration.
  --keep-gpg-key       Do not remove the test RPM repository GPG key.
  --keep-product-cert  Do not remove the default product certificate created
                       by configure-host.sh.
  -h, --help           Show this help.

With no options every change is reverted. Each step is skipped automatically
if the change is not present, so the script is safe to run repeatedly.

The subscription-manager configuration is restored from
\${CANDLEPIN_TEST_STATE_DIR:-\${XDG_STATE_HOME:-\$HOME/.local/state}/candlepin-test}/subscription-manager.conf.bak
created by configure-host.sh. The default product certificate created by
configure-host.sh is tracked in
\${CANDLEPIN_TEST_STATE_DIR:-\${XDG_STATE_HOME:-\$HOME/.local/state}/candlepin-test}/product-cert.created
and removed only when that marker exists (so a pre-existing RHEL certificate is
kept).

Environment:
  CANDLEPIN_TEST_STATE_DIR  Directory for subscription-manager backup
                            (default: \${XDG_STATE_HOME:-\$HOME/.local/state}/candlepin-test)
  XDG_STATE_HOME            Base directory for state files (default: \$HOME/.local/state)
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-etc-hosts)     RESTORE_ETC_HOSTS=0; shift ;;
    --keep-ca-cert)       RESTORE_CA_CERT=0; shift ;;
    --keep-subman)        RESTORE_SUBMAN=0; shift ;;
    --keep-gpg-key)       RESTORE_GPG_KEY=0; shift ;;
    --keep-product-cert)  RESTORE_PRODUCT_CERT=0; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    echo "ERROR: Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

CP_HOSTNAME="candlepin"
CA_CRT_FILE_NAME="candlepin-ca-bundle.crt"
CA_FILE_NAME=${CA_CRT_FILE_NAME%.crt}.pem
CA_PATH="/etc/rhsm/ca/${CA_FILE_NAME}"
ANCHOR_PATH="/etc/pki/ca-trust/source/anchors/${CA_FILE_NAME}"
# candlepin-repo's own CA installed by configure-host.sh.
REPO_CA_FILE_NAME="candlepin-repo-ca.pem"
REPO_CA_PATH="/etc/rhsm/ca/${REPO_CA_FILE_NAME}"
REPO_CA_ANCHOR_PATH="/etc/pki/ca-trust/source/anchors/${REPO_CA_FILE_NAME}"
GPG_KEY_PATH="/etc/pki/rpm-gpg/RPM-GPG-KEY-candlepin"

# State directory used by configure-host.sh to remember what it changed.
# Computed once here and reused for subscription-manager and product-cert
# restore. Mirrors the logic in configure-host.sh.
if [ -n "${CANDLEPIN_TEST_STATE_DIR:-}" ]; then
  _RESTORE_STATE_DIR="$CANDLEPIN_TEST_STATE_DIR"
else
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    _USER_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    [ -z "${_USER_HOME:-}" ] && _USER_HOME="$HOME"
  else
    _USER_HOME="$HOME"
  fi
  _RESTORE_STATE_DIR="${XDG_STATE_HOME:-$_USER_HOME/.local/state}/candlepin-test"
  unset _USER_HOME
fi
_STATE_FILE="$_RESTORE_STATE_DIR/subscription-manager.conf.bak"
_PRODUCT_CERT_STATE_FILE="$_RESTORE_STATE_DIR/product-cert.created"

# Matches only the exact "127.0.0.1 candlepin" line configure-host.sh writes,
# so a user-maintained line listing extra hostnames is left untouched.
HOSTS_RE="^127\.0\.0\.1[[:space:]]+${CP_HOSTNAME//./\\.}[[:space:]]*$"

# ---------------------------------------------------------------------------
# 1. /etc/hosts
# ---------------------------------------------------------------------------
if [ "$RESTORE_ETC_HOSTS" -eq 1 ]; then
  echo "[1/5] Removing ${CP_HOSTNAME} from /etc/hosts..."
  if grep -qE "$HOSTS_RE" /etc/hosts; then
    sudo cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    sudo sed -i -E "/${HOSTS_RE}/d" /etc/hosts
    echo "  removed (backup of /etc/hosts saved alongside it)"
  else
    echo "  no '127.0.0.1 ${CP_HOSTNAME}' line found, skipping"
  fi
else
  echo "[1/5] Keeping /etc/hosts (--keep-etc-hosts)"
fi

# ---------------------------------------------------------------------------
# 2. CA certificate / trust store
# ---------------------------------------------------------------------------
if [ "$RESTORE_CA_CERT" -eq 1 ]; then
  echo "[2/5] Removing Candlepin and repo CA certificates from the trust store..."
  removed_ca=0
  for path in "$ANCHOR_PATH" "$REPO_CA_ANCHOR_PATH"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      sudo rm -f "$path"
      removed_ca=1
    fi
  done
  for path in "$CA_PATH" "$REPO_CA_PATH"; do
    if [ -e "$path" ]; then
      sudo rm -f "$path"
      removed_ca=1
    fi
  done
  if [ "$removed_ca" -eq 1 ]; then
    if command -v update-ca-trust > /dev/null; then
      sudo update-ca-trust
    fi
    echo "  removed and trust store rebuilt"
  else
    echo "  CA certificate not present, skipping"
  fi
else
  echo "[2/5] Keeping Candlepin CA certificate (--keep-ca-cert)"
fi

# ---------------------------------------------------------------------------
# 3. subscription-manager
# ---------------------------------------------------------------------------
if [ "$RESTORE_SUBMAN" -eq 1 ]; then
  echo "[3/5] Restoring subscription-manager configuration..."
  if command -v subscription-manager > /dev/null; then
    STATE_DIR="$_RESTORE_STATE_DIR"
    STATE_FILE="$_STATE_FILE"
    if [ -f "$STATE_FILE" ]; then
      echo "  restoring from $STATE_FILE..."
      restore_failed=0
      while IFS='|' read -r key value is_default; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [ "$is_default" = "1" ]; then
          echo "  restoring $key to default"
          if ! sudo subscription-manager config --remove="$key"; then
            echo "ERROR: failed to restore $key to default" >&2
            restore_failed=1
          fi
        else
          echo "  restoring $key=$value"
          if ! sudo subscription-manager config --"$key"="$value"; then
            echo "ERROR: failed to restore $key=$value" >&2
            restore_failed=1
          fi
        fi
      done < <(cat "$STATE_FILE" 2>/dev/null || sudo cat "$STATE_FILE" 2>/dev/null || true)
      if [ "$restore_failed" -ne 0 ]; then
        echo "  restore failed for one or more keys (see errors above)" >&2
        exit 1
      fi
      echo "  resulting configuration:"
      sudo subscription-manager config --list 2>/dev/null | grep -E "^\[server\]|^\[rhsm\]|hostname|port|prefix|baseurl|repo_ca_cert" || true
      rm -f "$STATE_FILE" 2>/dev/null || sudo rm -f "$STATE_FILE" 2>/dev/null || true
      rmdir "$STATE_DIR" 2>/dev/null || sudo rmdir "$STATE_DIR" 2>/dev/null || true
      echo "  restored"
    else
      echo "  no backup file found, skipping"
      echo "  (looked in \${CANDLEPIN_TEST_STATE_DIR:-\${XDG_STATE_HOME:-\$HOME/.local/state}/candlepin-test}/subscription-manager.conf.bak)"
      echo "  (previous configuration was not saved by configure-host.sh;"
      echo "   to reset to Red Hat defaults manually, run:"
      echo "   sudo subscription-manager config --remove=server.hostname"
      echo "     --remove=server.port --remove=server.prefix"
      echo "     --remove=rhsm.baseurl --remove=rhsm.repo_ca_cert)"
    fi
  else
    echo "  subscription-manager not installed, skipping"
  fi
else
  echo "[3/5] Keeping subscription-manager configuration (--keep-subman)"
fi

# ---------------------------------------------------------------------------
# 4. GPG key
# ---------------------------------------------------------------------------
if [ "$RESTORE_GPG_KEY" -eq 1 ]; then
  echo "[4/5] Removing the test RPM repository GPG key..."
  if [ -e "$GPG_KEY_PATH" ]; then
    sudo rm -f "$GPG_KEY_PATH"
    echo "  removed"
  else
    echo "  GPG key not present, skipping"
  fi
else
  echo "[4/5] Keeping the test RPM repository GPG key (--keep-gpg-key)"
fi

# ---------------------------------------------------------------------------
# 5. Product certificate — only remove what configure-host.sh created
# ---------------------------------------------------------------------------
if [ "$RESTORE_PRODUCT_CERT" -eq 1 ]; then
  echo "[5/5] Removing default product certificate created by configure-host.sh..."
  _PC_STATE_FILE="$_PRODUCT_CERT_STATE_FILE"
  if [ -f "$_PC_STATE_FILE" ]; then
    while IFS= read -r _pc_path || [ -n "$_pc_path" ]; do
      [ -z "$_pc_path" ] && continue
      if [ -e "$_pc_path" ]; then
        echo "  removing $_pc_path"
        sudo rm -f "$_pc_path"
      fi
    done < <(cat "$_PC_STATE_FILE" 2>/dev/null || sudo cat "$_PC_STATE_FILE" 2>/dev/null || true)
    rm -f "$_PC_STATE_FILE" 2>/dev/null || sudo rm -f "$_PC_STATE_FILE" 2>/dev/null || true
    rmdir "$(dirname "$_PC_STATE_FILE")" 2>/dev/null || sudo rmdir "$(dirname "$_PC_STATE_FILE")" 2>/dev/null || true
    echo "  removed"
  else
    echo "  no product-cert marker found, keeping existing certificate(s)"
  fi
else
  echo "[5/5] Keeping product certificate (--keep-product-cert)"
fi

echo "Done. Host changes made by configure-host.sh have been reverted."
