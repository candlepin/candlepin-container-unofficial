#!/bin/bash
# configure-host.sh — Configure the host system to use Candlepin running in the pod.
#
# Run this as a regular user (not via sudo) after starting the pod with
# `podman play kube candlepin-pod.yaml`. Rootless podman containers are only
# visible to the user who started them; privileged steps use sudo internally.
#
# Usage:
#   configure-host.sh [container]
#
#   container   Name of the candlepin-app container
#               (default: candlepin-candlepin-app, the name podman gives it in the pod;
#                use "candlepin" for the container network setup)
#
# This script:
# 1. Adds candlepin to /etc/hosts
# 2. Installs Candlepin's CA certificate into /etc/rhsm/ca and the system trust store
# 3. Configures subscription-manager to use the Candlepin server and test repos
# 4. Imports the GPG key of the test RPM repository

set -euo pipefail

usage() {
  cat <<EOF
Configure the host system to use Candlepin running in the pod.

Usage: $(basename "$0") [options] [container]

Arguments:
  container    Name of the candlepin-app container
               (default: candlepin-candlepin-app, the name podman gives it in
               the pod; use "candlepin" for the container network setup).

Options:
  -h, --help   Show this help.

This script:
  1. Adds candlepin to /etc/hosts
  2. Installs Candlepin's CA certificate into /etc/rhsm/ca and the system
     trust store
  3. Configures subscription-manager to use the Candlepin server and test repos
  4. Imports the GPG key of the test RPM repository

The current subscription-manager configuration for server.hostname,
server.port, server.prefix, rhsm.baseurl and rhsm.repo_ca_cert is saved
to \${CANDLEPIN_TEST_STATE_DIR:-\${XDG_STATE_HOME:-\$HOME/.local/state}/candlepin-test}/subscription-manager.conf.bak
before being overwritten, so restore-host.sh can restore it.

Environment:
  CANDLEPIN_TEST_STATE_DIR  Directory for subscription-manager backup
                            (default: \${XDG_STATE_HOME:-\$HOME/.local/state}/candlepin-test)
  XDG_STATE_HOME            Base directory for state files (default: \$HOME/.local/state)

Examples:
  ./configure-host.sh
  CANDLEPIN_TEST_STATE_DIR=/tmp/my-backup ./configure-host.sh
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONTAINER="candlepin-candlepin-app"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)  usage; exit 0 ;;
    -*)         echo "ERROR: Unknown option: $1 (try --help)" >&2; exit 1 ;;
    *)          CONTAINER="$1"; shift ;;
  esac
done
CP_HOSTNAME="candlepin"
CP_PORT=8443
CP_PREFIX="/candlepin"
REPO_URL="https://${CP_HOSTNAME}:9443"
CA_CRT_FILE_NAME="candlepin-ca-bundle.crt"
CA_FILE_NAME=${CA_CRT_FILE_NAME%.crt}.pem
CA_PATH="/etc/rhsm/ca/${CA_FILE_NAME}"
ANCHOR_PATH="/etc/pki/ca-trust/source/anchors/${CA_FILE_NAME}"
# candlepin-repo serves its test yum repos over HTTPS with its own independent CA
# (candlepin-repo-ca.crt), separate from candlepin's API CA. We install it
# alongside the candlepin CA and point rhsm.repo_ca_cert at a combined bundle so
# repo content validates. REPO_CONTAINER is the candlepin-repo container; in the
# shared-namespace pod it is a sibling of the app container.
REPO_CONTAINER="candlepin-candlepin-repo"
REPO_CA_CRT_FILE_NAME="candlepin-repo-ca.crt"
REPO_CA_FILE_NAME=${REPO_CA_CRT_FILE_NAME%.crt}.pem
REPO_CA_PATH="/etc/rhsm/ca/${REPO_CA_FILE_NAME}"
REPO_CA_ANCHOR_PATH="/etc/pki/ca-trust/source/anchors/${REPO_CA_FILE_NAME}"
# Combined bundle (candlepin API CA + repo CA) used as rhsm.repo_ca_cert.
COMBINED_CA_FILE_NAME="candlepin-combined-ca-bundle.pem"
COMBINED_CA_PATH="/etc/rhsm/ca/${COMBINED_CA_FILE_NAME}"
GPG_KEY_PATH="/etc/pki/rpm-gpg/RPM-GPG-KEY-candlepin"
# Backup of subscription-manager configuration is stored in the invoking user's
# home directory so it does not require privileged access and survives sudo.
# XDG_STATE_HOME is respected; override with CANDLEPIN_TEST_STATE_DIR.
if [ -n "${CANDLEPIN_TEST_STATE_DIR:-}" ]; then
  STATE_DIR="$CANDLEPIN_TEST_STATE_DIR"
else
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    _USER_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    [ -z "${_USER_HOME:-}" ] && _USER_HOME="$HOME"
  else
    _USER_HOME="$HOME"
  fi
  STATE_DIR="${XDG_STATE_HOME:-$_USER_HOME/.local/state}/candlepin-test"
  unset _USER_HOME
fi
STATE_FILE="$STATE_DIR/subscription-manager.conf.bak"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  echo "WARNING: running via sudo; rootless containers of ${SUDO_USER} will not be visible." >&2
fi

for cmd in podman curl subscription-manager; do
  if ! command -v "$cmd" > /dev/null; then
    echo "ERROR: '$cmd' is not installed." >&2
    exit 1
  fi
done

if ! podman container exists "$CONTAINER"; then
  echo "ERROR: container '$CONTAINER' does not exist. Start the pod first:" >&2
  echo "  podman play kube candlepin-pod.yaml" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# TLS Certificate Trust
# ---------------------------------------------------------------------------

echo "[1/5] Adding ${CP_HOSTNAME} to /etc/hosts..."
if grep -qE "^127\.0\.0\.1[[:space:]]+${CP_HOSTNAME//./\\.}([[:space:]]|$)" /etc/hosts; then
  echo "  ${CP_HOSTNAME} is already present in /etc/hosts, skipping"
else
  echo "127.0.0.1 ${CP_HOSTNAME}" | sudo tee -a /etc/hosts > /dev/null
fi

echo "[2/5] Installing Candlepin and repo CA certificates..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
# Candlepin API CA.
podman cp "${CONTAINER}:/etc/candlepin/certs/${CA_CRT_FILE_NAME}" "${TMP_DIR}/${CA_FILE_NAME}"
sudo install -D -o root -g root -m 0644 "${TMP_DIR}/${CA_FILE_NAME}" "$CA_PATH"
sudo ln -sf "$CA_PATH" "$ANCHOR_PATH"
# candlepin-repo's own independent CA.
podman cp "${REPO_CONTAINER}:/etc/pki/tls/certs/${REPO_CA_CRT_FILE_NAME}" "${TMP_DIR}/${REPO_CA_FILE_NAME}"
sudo install -D -o root -g root -m 0644 "${TMP_DIR}/${REPO_CA_FILE_NAME}" "$REPO_CA_PATH"
sudo ln -sf "$REPO_CA_PATH" "$REPO_CA_ANCHOR_PATH"
# Combined bundle for rhsm.repo_ca_cert (subscription-manager accepts a single file).
cat "${TMP_DIR}/${CA_FILE_NAME}" "${TMP_DIR}/${REPO_CA_FILE_NAME}" > "${TMP_DIR}/${COMBINED_CA_FILE_NAME}"
sudo install -D -o root -g root -m 0644 "${TMP_DIR}/${COMBINED_CA_FILE_NAME}" "$COMBINED_CA_PATH"
sudo update-ca-trust
if command -v restorecon > /dev/null; then
  sudo restorecon -v "$CA_PATH" "$REPO_CA_PATH" "$COMBINED_CA_PATH"
fi

echo "[3/5] Verifying TLS connection to https://${CP_HOSTNAME}:${CP_PORT}${CP_PREFIX}/status ..."
if ! curl -sSf -o /dev/null "https://${CP_HOSTNAME}:${CP_PORT}${CP_PREFIX}/status"; then
  echo "ERROR: Candlepin status check failed (is the server fully started?)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Subscription Manager configuration
# ---------------------------------------------------------------------------

echo "[4/5] Configuring subscription-manager..."
# Save current subscription-manager configuration for the keys we will
# overwrite so restore-host.sh can restore the host's previous values
# instead of resetting to Red Hat defaults. The backup records value and
# whether it was a default (marked with [] in `config --list`).
if [ ! -f "$STATE_FILE" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || sudo mkdir -p "$STATE_DIR"
  SM_LIST="$(subscription-manager config --list 2>/dev/null || sudo subscription-manager config --list 2>/dev/null || true)"
  {
    echo "# Backup created by configure-host.sh on $(date -Iseconds 2>/dev/null || date)"
    for key in server.hostname server.port server.prefix rhsm.baseurl rhsm.repo_ca_cert; do
      section="${key%%.*}"
      name="${key#*.}"
      raw_val="$(printf '%s\n' "$SM_LIST" | awk -v sec="[$section]" -v n="$name" '
        $0 == sec { in_sec=1; next }
        /^\[.*\]/ { in_sec=0 }
        in_sec && $1 == n && $2 == "=" {
          $1=""; $2=""; sub(/^  */, "", $0); print $0; exit
        }
      ')"
      is_default=0
      val="$raw_val"
      if [[ "$val" =~ ^\[(.*)\]$ ]]; then
        is_default=1
        val="${BASH_REMATCH[1]}"
      fi
      printf '%s|%s|%s\n' "$key" "$val" "$is_default"
    done
  } | tee "$STATE_FILE" >/dev/null 2>&1 || sudo tee "$STATE_FILE" >/dev/null
  chmod 0600 "$STATE_FILE" 2>/dev/null || sudo chmod 0600 "$STATE_FILE" 2>/dev/null || true
  echo "  saved previous subscription-manager configuration to $STATE_FILE"
fi
# repo_ca_cert is written as sslcacert into the generated repo files. Since
# candlepin-repo now has its own CA, point it at the combined bundle (candlepin
# API CA + repo CA) so the test repos served over HTTPS by candlepin-repo validate.
sudo subscription-manager config \
  --server.hostname "$CP_HOSTNAME" \
  --server.port "$CP_PORT" \
  --server.prefix "$CP_PREFIX" \
  --rhsm.baseurl "$REPO_URL" \
  --rhsm.repo_ca_cert "$COMBINED_CA_PATH"

echo "[5/5] Importing GPG key of the test RPM repository..."
curl -sSf -o "${TMP_DIR}/RPM-GPG-KEY-candlepin" "${REPO_URL}/RPM-GPG-KEY-candlepin"
sudo install -D -o root -g root -m 0644 "${TMP_DIR}/RPM-GPG-KEY-candlepin" "$GPG_KEY_PATH"

echo "Done. The system is configured to use Candlepin at https://${CP_HOSTNAME}:${CP_PORT}${CP_PREFIX}"
