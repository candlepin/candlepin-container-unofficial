#!/bin/bash
# create-product-cert.sh — Generate a (fake) installed product certificate with
# release tags and install it into /etc/pki/product-default on the host.
#
# subscription-manager only enables content whose "required_tags" are provided
# by a product certificate installed on the system (normally shipped by the OS
# in /etc/pki/product or /etc/pki/product-default). Fedora does not ship such a
# certificate, so to test tag/release-gated content (e.g. the "fedora-45"
# content in test_data.json) we generate one here, signed by the Candlepin CA.
#
# Defaults are derived from /etc/os-release so the certificate matches the
# running distribution (e.g. tags "fedora-45" on Fedora 45, "rhel-10" on RHEL
# 10). This way the script keeps working across OS updates and on other
# distributions without being edited. Override any field via options.
#
# Run as a regular user (not via sudo); privileged steps use sudo internally,
# mirroring configure-host.sh.
#
# Usage:
#   create-product-cert.sh [options] [container]

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults derived from /etc/os-release
# ---------------------------------------------------------------------------
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
_ID=""; _VERSION_ID=""; _NAME=""
if [ -r "$OS_RELEASE_FILE" ]; then
  # /etc/os-release is designed to be sourced; do it in a subshell and export
  # back only the fields we need, so we don't pollute this script's namespace.
  eval "$(
    . "$OS_RELEASE_FILE" >/dev/null 2>&1
    printf '_ID=%q\n_VERSION_ID=%q\n_NAME=%q\n' "${ID:-}" "${VERSION_ID:-}" "${NAME:-}"
  )"
fi
# Major version only (e.g. RHEL "10.0" -> "10"); used for the tag and the
# product id, matching how required_tags are written (e.g. "rhel-10").
_MAJOR="${_VERSION_ID%%.*}"

CONTAINER="candlepin-candlepin-app"
PRODUCT_ID="${_MAJOR}"
PRODUCT_NAME="${_NAME:-Linux}"
PRODUCT_VERSION="${_VERSION_ID}"
PRODUCT_ARCH="$(uname -m)"
PRODUCT_TAGS="${_ID:-linux}-${_MAJOR}"
BRAND_TYPE=""
BRAND_NAME=""
INSTALL_DIR="/etc/pki/product-default"
INSTALL=1

# OID prefix for Red Hat product certificates.
OID_BASE="1.3.6.1.4.1.2312.9.1"
# CA material inside the candlepin-app container (the RSA CA that signs
# product certificates); these are the "ent-product-ca" files from the doc.
CA_CRT_IN_CONTAINER="/etc/candlepin/certs/candlepin-ca.crt"
CA_KEY_IN_CONTAINER="/etc/candlepin/certs/candlepin-ca.key"

usage() {
  cat <<EOF
Generate a (fake) installed product certificate with release tags and install
it into ${INSTALL_DIR} so subscription-manager enables content gated on those
tags (e.g. the "fedora-45" test content).

Usage: $(basename "$0") [options] [container]

Arguments:
  container            Name of the candlepin-app container
                       (default: ${CONTAINER}).

Options:
  --product-id ID      Product ID; also the certificate file name <ID>.pem
                       (default: ${PRODUCT_ID}).
  --name NAME          Product name (default: "${PRODUCT_NAME}").
  --version VERSION    Product version (default: ${PRODUCT_VERSION}).
  --arch ARCH          Product architecture (default: ${PRODUCT_ARCH}).
  --tags TAGS          Comma-separated provided tags; these must match the
                       content "required_tags" (default: ${PRODUCT_TAGS}).
  --brand-type TYPE    Optional brand type.
  --brand-name NAME    Optional brand name.
  --install-dir DIR    Directory to install the certificate into
                       (default: ${INSTALL_DIR}).
  --no-install         Only write <ID>.pem to the current directory; do not
                       install into ${INSTALL_DIR}.
  -h, --help           Show this help.

Examples:
  # Use defaults derived from /etc/os-release for the running distribution
  ./create-product-cert.sh

  # Override the tags/name explicitly
  ./create-product-cert.sh --product-id 999 --name "Example Product" --tags tag-1,tag-2

  # Just emit the PEM without installing
  ./create-product-cert.sh --no-install
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --product-id)   PRODUCT_ID="$2"; shift 2 ;;
    --name)         PRODUCT_NAME="$2"; shift 2 ;;
    --version)      PRODUCT_VERSION="$2"; shift 2 ;;
    --arch)         PRODUCT_ARCH="$2"; shift 2 ;;
    --tags)         PRODUCT_TAGS="$2"; shift 2 ;;
    --brand-type)   BRAND_TYPE="$2"; shift 2 ;;
    --brand-name)   BRAND_NAME="$2"; shift 2 ;;
    --install-dir)  INSTALL_DIR="$2"; shift 2 ;;
    --no-install)   INSTALL=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "ERROR: Unknown option: $1 (try --help)" >&2; exit 1 ;;
    *)              CONTAINER="$1"; shift ;;
  esac
done

# The product id becomes an OID arc (and the <id>.pem file name), so it must be
# a non-negative integer. It may be empty here if /etc/os-release had no usable
# VERSION_ID and --product-id was not given.
if ! [[ "$PRODUCT_ID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not determine a numeric product id from ${OS_RELEASE_FILE}." >&2
  echo "       Pass one explicitly, e.g. --product-id 999." >&2
  exit 1
fi
if [ -z "$PRODUCT_TAGS" ]; then
  echo "ERROR: no product tags determined; pass --tags (e.g. --tags fedora-45)." >&2
  exit 1
fi

for cmd in podman openssl; do
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

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# Fetch the Candlepin CA (signs the product certificate)
# ---------------------------------------------------------------------------
echo "[1/4] Fetching Candlepin CA from container '${CONTAINER}'..."
podman cp "${CONTAINER}:${CA_CRT_IN_CONTAINER}" "${TMP_DIR}/ent-product-ca.crt"
podman cp "${CONTAINER}:${CA_KEY_IN_CONTAINER}" "${TMP_DIR}/ent-product-ca.key"

# ---------------------------------------------------------------------------
# Build the OpenSSL extension file describing the product
# ---------------------------------------------------------------------------
echo "[2/4] Building product extension file (id=${PRODUCT_ID}, tags=${PRODUCT_TAGS})..."
EXTFILE="${TMP_DIR}/productid_${PRODUCT_ID}.txt"
{
  echo "[productid]"
  echo "basicConstraints=CA:FALSE"
  echo "${OID_BASE}.${PRODUCT_ID}.1=ASN1:UTF8:${PRODUCT_NAME}"
  echo "${OID_BASE}.${PRODUCT_ID}.2=ASN1:UTF8:${PRODUCT_VERSION}"
  echo "${OID_BASE}.${PRODUCT_ID}.3=ASN1:UTF8:${PRODUCT_ARCH}"
  echo "${OID_BASE}.${PRODUCT_ID}.4=ASN1:UTF8:${PRODUCT_TAGS}"
  [ -n "$BRAND_TYPE" ] && echo "${OID_BASE}.${PRODUCT_ID}.5=ASN1:UTF8:${BRAND_TYPE}"
  [ -n "$BRAND_NAME" ] && echo "${OID_BASE}.${PRODUCT_ID}.6=ASN1:UTF8:${BRAND_NAME}"
} > "$EXTFILE"

# ---------------------------------------------------------------------------
# Generate key, CSR and sign the product certificate
# ---------------------------------------------------------------------------
echo "[3/4] Generating and signing product certificate ${PRODUCT_ID}.pem..."
openssl genrsa -out "${TMP_DIR}/product-csr.key" 2>/dev/null

openssl req -new \
  -key "${TMP_DIR}/product-csr.key" \
  -out "${TMP_DIR}/productid_${PRODUCT_ID}.req" \
  -subj '/CN=Product ID [00000000-0000-0000-0000-000000000000]'

echo "01" > "${TMP_DIR}/ent-product-ca.srl"

CERT_OUT="${TMP_DIR}/${PRODUCT_ID}.pem"
openssl x509 -req \
  -sha256 -days 7305 \
  -in "${TMP_DIR}/productid_${PRODUCT_ID}.req" \
  -out "$CERT_OUT" \
  -extfile "$EXTFILE" \
  -extensions productid \
  -CA "${TMP_DIR}/ent-product-ca.crt" \
  -CAkey "${TMP_DIR}/ent-product-ca.key" \
  -CAserial "${TMP_DIR}/ent-product-ca.srl" 2>/dev/null

# ---------------------------------------------------------------------------
# Install (or emit) the certificate
# ---------------------------------------------------------------------------
if [ "$INSTALL" -eq 1 ]; then
  echo "[4/4] Installing certificate into ${INSTALL_DIR}/${PRODUCT_ID}.pem..."
  sudo install -D -o root -g root -m 0644 "$CERT_OUT" "${INSTALL_DIR}/${PRODUCT_ID}.pem"
  if command -v restorecon > /dev/null; then
    sudo restorecon -v "${INSTALL_DIR}/${PRODUCT_ID}.pem" >/dev/null 2>&1 || true
  fi
  echo "Done. Installed product certificate providing tags: ${PRODUCT_TAGS}"
else
  cp "$CERT_OUT" "./${PRODUCT_ID}.pem"
  echo "[4/4] Wrote ./${PRODUCT_ID}.pem (not installed)."
  echo "Done. Copy it to ${INSTALL_DIR}/ to enable tag-gated content."
fi
