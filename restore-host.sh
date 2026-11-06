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
# 3. The subscription-manager server/repo configuration (reset to defaults)
# 4. The imported test RPM repository GPG key
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

usage() {
  cat <<EOF
Undo the host changes made by configure-host.sh.

Usage: $(basename "$0") [options]

Options:
  --keep-etc-hosts     Do not remove the "127.0.0.1 candlepin" entry from
                       /etc/hosts.
  --keep-ca-cert       Do not remove the Candlepin CA certificate from
                       /etc/rhsm/ca and the system trust store.
  --keep-subman        Do not reset the subscription-manager configuration.
  --keep-gpg-key       Do not remove the test RPM repository GPG key.
  -h, --help           Show this help.

With no options every change is reverted. Each step is skipped automatically
if the change is not present, so the script is safe to run repeatedly.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-etc-hosts)  RESTORE_ETC_HOSTS=0; shift ;;
    --keep-ca-cert)    RESTORE_CA_CERT=0; shift ;;
    --keep-subman)     RESTORE_SUBMAN=0; shift ;;
    --keep-gpg-key)    RESTORE_GPG_KEY=0; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 echo "ERROR: Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

CP_HOSTNAME="candlepin"
CA_CRT_FILE_NAME="candlepin-ca-bundle.crt"
CA_FILE_NAME=${CA_CRT_FILE_NAME%.crt}.pem
CA_PATH="/etc/rhsm/ca/${CA_FILE_NAME}"
ANCHOR_PATH="/etc/pki/ca-trust/source/anchors/${CA_FILE_NAME}"
GPG_KEY_PATH="/etc/pki/rpm-gpg/RPM-GPG-KEY-candlepin"

# Matches only the exact "127.0.0.1 candlepin" line configure-host.sh writes,
# so a user-maintained line listing extra hostnames is left untouched.
HOSTS_RE="^127\.0\.0\.1[[:space:]]+${CP_HOSTNAME//./\\.}[[:space:]]*$"

# ---------------------------------------------------------------------------
# 1. /etc/hosts
# ---------------------------------------------------------------------------
if [ "$RESTORE_ETC_HOSTS" -eq 1 ]; then
  echo "[1/4] Removing ${CP_HOSTNAME} from /etc/hosts..."
  if grep -qE "$HOSTS_RE" /etc/hosts; then
    sudo cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    sudo sed -i -E "/${HOSTS_RE}/d" /etc/hosts
    echo "  removed (backup of /etc/hosts saved alongside it)"
  else
    echo "  no '127.0.0.1 ${CP_HOSTNAME}' line found, skipping"
  fi
else
  echo "[1/4] Keeping /etc/hosts (--keep-etc-hosts)"
fi

# ---------------------------------------------------------------------------
# 2. CA certificate / trust store
# ---------------------------------------------------------------------------
if [ "$RESTORE_CA_CERT" -eq 1 ]; then
  echo "[2/4] Removing Candlepin CA certificate from the trust store..."
  removed_ca=0
  if [ -e "$ANCHOR_PATH" ] || [ -L "$ANCHOR_PATH" ]; then
    sudo rm -f "$ANCHOR_PATH"
    removed_ca=1
  fi
  if [ -e "$CA_PATH" ]; then
    sudo rm -f "$CA_PATH"
    removed_ca=1
  fi
  if [ "$removed_ca" -eq 1 ]; then
    if command -v update-ca-trust > /dev/null; then
      sudo update-ca-trust
    fi
    echo "  removed and trust store rebuilt"
  else
    echo "  CA certificate not present, skipping"
  fi
else
  echo "[2/4] Keeping Candlepin CA certificate (--keep-ca-cert)"
fi

# ---------------------------------------------------------------------------
# 3. subscription-manager
# ---------------------------------------------------------------------------
if [ "$RESTORE_SUBMAN" -eq 1 ]; then
  echo "[3/4] Resetting subscription-manager configuration to defaults..."
  if command -v subscription-manager > /dev/null; then
    # --remove resets each option to its built-in default.
    sudo subscription-manager config \
      --remove=server.hostname \
      --remove=server.port \
      --remove=server.prefix \
      --remove=rhsm.baseurl \
      --remove=rhsm.repo_ca_cert || true
    echo "  reset"
  else
    echo "  subscription-manager not installed, skipping"
  fi
else
  echo "[3/4] Keeping subscription-manager configuration (--keep-subman)"
fi

# ---------------------------------------------------------------------------
# 4. GPG key
# ---------------------------------------------------------------------------
if [ "$RESTORE_GPG_KEY" -eq 1 ]; then
  echo "[4/4] Removing the test RPM repository GPG key..."
  if [ -e "$GPG_KEY_PATH" ]; then
    sudo rm -f "$GPG_KEY_PATH"
    echo "  removed"
  else
    echo "  GPG key not present, skipping"
  fi
else
  echo "[4/4] Keeping the test RPM repository GPG key (--keep-gpg-key)"
fi

echo "Done. Host changes made by configure-host.sh have been reverted."
