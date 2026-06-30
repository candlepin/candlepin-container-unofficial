#!/bin/bash
# provision.sh — Run inside the candlepin-app container during build-time provisioning.
#
# Expects PostgreSQL to be reachable at the host configured in candlepin.conf
# (typically "postgres" via container network DNS).
#
# Usage:
#   provision.sh              # run all phases
#   provision.sh <phase>      # run a single phase (install-deps, wait-api, validate,
#                             #   import-data, create-repos, copy-certs, cleanup)
#
# This script:
# 1. Waits for Candlepin to become responsive (implies Liquibase + DB ready)
# 2. Imports test data (owners, users, products, content)
# 3. Creates test RPM repositories
# 4. Copies generated certs to the expected location

set -euo pipefail

MARKER="/opt/test-data/.provisioned"
PROV_PKGS="python3-requests createrepo_c rpm-build rpm-sign expect hostname gnupg2"

# ---------------------------------------------------------------------------
# Phase functions
# ---------------------------------------------------------------------------

phase_install_deps() {
  echo "[phase 0/6] Installing provisioning dependencies..."

  RELEASEVER=$(rpm -E %rhel)
  CENTOS_STREAM="stream-${RELEASEVER}"
  CENTOS_COMPOSE="https://composes.stream.centos.org/${CENTOS_STREAM}/production/latest-CentOS-Stream/compose"
  rpm --import "https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official-SHA256" 2>/dev/null || true
  cat > /etc/yum.repos.d/centos-provision.repo << REPOEOF
[centos-provision-baseos]
name=CentOS Stream ${RELEASEVER} - BaseOS (provisioning)
baseurl=${CENTOS_COMPOSE}/BaseOS/\$basearch/os/
gpgcheck=1
gpgkey=https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official-SHA256
enabled=1

[centos-provision-appstream]
name=CentOS Stream ${RELEASEVER} - AppStream (provisioning)
baseurl=${CENTOS_COMPOSE}/AppStream/\$basearch/os/
gpgcheck=1
gpgkey=https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official-SHA256
enabled=1
REPOEOF

  PKG_MGR=$(command -v microdnf 2>/dev/null || command -v dnf 2>/dev/null || command -v yum 2>/dev/null)
  $PKG_MGR --setopt=install_weak_deps=0 -y install $PROV_PKGS
}

phase_wait_api() {
  echo "[phase 1/6] Waiting for Candlepin API..."

  MAX_WAIT=300
  ELAPSED=0
  while [ $ELAPSED -lt $MAX_WAIT ]; do
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:8443/candlepin/status 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
      echo "[phase 1/6] Candlepin is ready (took ${ELAPSED}s)"
      return 0
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $((ELAPSED % 30)) -eq 0 ]; then
      echo "  ...waiting ($ELAPSED/${MAX_WAIT}s, last HTTP code: $HTTP_CODE)"
    fi
  done

  echo "ERROR: Candlepin failed to start within ${MAX_WAIT}s (last HTTP code: $HTTP_CODE)"
  echo "=== catalina.out (last 100 lines) ==="
  tail -100 /opt/tomcat/logs/catalina.out 2>/dev/null || true
  echo "=== candlepin.log (last 50 lines) ==="
  tail -50 /var/log/candlepin/candlepin.log 2>/dev/null || true
  exit 1
}

phase_validate() {
  echo "[phase 2/6] Validating required files..."
  cd /opt/test-data
  for required_file in test_data_importer.py test_data.json create_test_repos.py; do
    if [ ! -f "$required_file" ]; then
      echo "ERROR: Missing required file: /opt/test-data/$required_file"
      exit 1
    fi
  done
}

phase_import_data() {
  echo "[phase 3/6] Importing test data..."
  cd /opt/test-data
  if ! python3 test_data_importer.py --host localhost --port 8443 --username admin --password admin test_data.json; then
    echo "ERROR: test_data_importer.py failed (exit code $?)"
    exit 1
  fi

  OWNER_COUNT=$(curl -sk -u admin:admin https://localhost:8443/candlepin/owners 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  if [ "$OWNER_COUNT" = "0" ]; then
    echo "ERROR: No owners found after import — database may be empty"
    exit 1
  fi
  echo "[phase 3/6] Import complete ($OWNER_COUNT owners in database)"
}

phase_create_repos() {
  echo "[phase 4/6] Creating test RPM repositories..."
  cd /opt/test-data
  if ! python3 create_test_repos.py test_data.json; then
    echo "ERROR: create_test_repos.py failed (exit code $?)"
    exit 1
  fi
}

phase_copy_certs() {
  echo "[phase 5/6] Copying generated certs..."
  if [ -d /opt/test-data/generated_certs ] && [ "$(ls -A /opt/test-data/generated_certs 2>/dev/null)" ]; then
    mkdir -p /home/candlepin/generated_certs
    cp -a /opt/test-data/generated_certs/* /home/candlepin/generated_certs/
    chmod -R o+rX /home/candlepin /home/candlepin/generated_certs
    CERT_COUNT=$(find /opt/test-data/generated_certs -maxdepth 1 -type f | wc -l)
    echo "[phase 5/6] Copied $CERT_COUNT cert files"
  else
    echo "WARNING: No generated_certs found at /opt/test-data/generated_certs"
  fi
}

phase_cleanup() {
  echo "[phase 6/6] Removing provisioning dependencies..."
  PKG_MGR=$(command -v microdnf 2>/dev/null || command -v dnf 2>/dev/null || command -v yum 2>/dev/null)
  $PKG_MGR remove -y $PROV_PKGS 2>/dev/null && $PKG_MGR clean all 2>/dev/null || true
  rm -f /etc/yum.repos.d/centos-provision.repo

  touch "$MARKER"
  echo "=== Provisioning complete ==="
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

run_all() {
  if [ -f "$MARKER" ]; then
    echo "Already provisioned. Exiting."
    exit 0
  fi
  echo "=== Provisioning Candlepin test data ==="
  phase_install_deps
  phase_wait_api
  phase_validate
  phase_import_data
  phase_create_repos
  phase_copy_certs
  phase_cleanup
}

case "${1:-all}" in
  all)            run_all ;;
  install-deps)   phase_install_deps ;;
  wait-api)       phase_wait_api ;;
  validate)       phase_validate ;;
  import-data)    phase_import_data ;;
  create-repos)   phase_create_repos ;;
  copy-certs)     phase_copy_certs ;;
  cleanup)        phase_cleanup ;;
  *)
    echo "Unknown phase: $1"
    echo "Valid phases: install-deps, wait-api, validate, import-data, create-repos, copy-certs, cleanup"
    exit 1
    ;;
esac
