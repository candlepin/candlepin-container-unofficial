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

CONTAINER="${1:-candlepin-candlepin-app}"
CP_HOSTNAME="candlepin"
CP_PORT=8443
CP_PREFIX="/candlepin"
REPO_URL="http://${CP_HOSTNAME}:8080"
CA_CRT_FILE_NAME="candlepin-ca-bundle.crt"
CA_FILE_NAME=${CA_CRT_FILE_NAME%.crt}.pem
CA_PATH="/etc/rhsm/ca/${CA_FILE_NAME}"
ANCHOR_PATH="/etc/pki/ca-trust/source/anchors/${CA_FILE_NAME}"
GPG_KEY_PATH="/etc/pki/rpm-gpg/RPM-GPG-KEY-candlepin"

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

echo "[2/5] Installing Candlepin CA certificate..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
podman cp "${CONTAINER}:/etc/candlepin/certs/${CA_CRT_FILE_NAME}" "${TMP_DIR}/${CA_FILE_NAME}"
sudo install -D -o root -g root -m 0644 "${TMP_DIR}/${CA_FILE_NAME}" "$CA_PATH"
sudo ln -sf "$CA_PATH" "$ANCHOR_PATH"
sudo update-ca-trust
if command -v restorecon > /dev/null; then
  sudo restorecon -v "$CA_PATH"
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
sudo subscription-manager config \
  --server.hostname "$CP_HOSTNAME" \
  --server.port "$CP_PORT" \
  --server.prefix "$CP_PREFIX" \
  --rhsm.baseurl "$REPO_URL"

echo "[5/5] Importing GPG key of the test RPM repository..."
curl -sSf -o "${TMP_DIR}/RPM-GPG-KEY-candlepin" "${REPO_URL}/RPM-GPG-KEY-candlepin"
sudo install -D -o root -g root -m 0644 "${TMP_DIR}/RPM-GPG-KEY-candlepin" "$GPG_KEY_PATH"

echo "Done. The system is configured to use Candlepin at https://${CP_HOSTNAME}:${CP_PORT}${CP_PREFIX}"
