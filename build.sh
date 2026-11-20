#!/bin/bash
# build.sh — Build (and optionally test/push) the three Candlepin test containers
# locally: candlepin-db, candlepin-app and candlepin-repo. Run with --help for
# the full usage. The whole provisioning flow (boot DB + app on a network,
# import test data via provision.sh, bake the repos, commit the images) lives
# here so the GitHub workflow can be a thin wrapper around this script.

# -E (errtrace) propagates the ERR trap into functions so on_error can report
# the exact command that failed; the real work all happens inside functions.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
UPSTREAM_IMAGE="quay.io/candlepin/candlepin:dev-latest"
HTTPD_IMAGE="quay.io/hummingbird/httpd:latest"
CANDLEPIN_REF="main"
DEPLOYMENT_DIR=""
TAG=""
REGISTRY="ghcr.io/candlepin"
UPDATE_LATEST=1
RUN_TEST=1
CREATE_POD=1
DO_PUSH=0
KEEP=0

APP_IMAGE_NAME="candlepin-app"
REPO_IMAGE_NAME="candlepin-repo"
DB_IMAGE_NAME="candlepin-db"
PROXY_IMAGE_NAME="candlepin-proxy"

# Build-scoped names (prefixed so we never clobber the user's own containers).
NET="cpbuild-net"
DB_C="cpbuild-db"
APP_C="cpbuild-app"
REPO_C="cpbuild-repo"
# Candlepin connects to db_host=postgres from candlepin.conf, so the DB
# container must resolve as "postgres" on the build network.
DB_ALIAS="postgres"

# Smoke-test-scoped names (separate from the provisioning ones above).
TEST_NET="cpbuild-test-net"
TEST_DB_C="cpbuild-test-db"
TEST_APP_C="cpbuild-test-app"
TEST_REPO_C="cpbuild-test-repo"
TEST_PROXY_C="cpbuild-test-proxy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POD_FILE="$SCRIPT_DIR/candlepin-pod.yaml"
POD_NAME="candlepin"
TMP_DIR=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
die()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
  cat <<EOF
Build (and optionally test/push) the three Candlepin test containers locally:

  candlepin-db    PostgreSQL with pre-baked schema + test data
  candlepin-app   Candlepin API with pre-baked test data (on top of the upstream image)
  candlepin-repo  Apache serving the generated test yum repositories

Usage: $(basename "$0") [options]

Options:
  --upstream-image IMG   Upstream candlepin image used as the app base
                         (default: quay.io/candlepin/candlepin:dev-latest)
  --httpd-image IMG      httpd base image for the repo container
                         (default: quay.io/hummingbird/httpd:latest)
  --candlepin-ref REF    candlepin git ref to fetch the test-data scripts from
                         (default: main). Ignored when --deployment-dir is set.
  --deployment-dir DIR   Use an existing bin/deployment directory instead of
                         cloning candlepin (e.g. a local candlepin checkout).
  --tag TAG              Image tag (default: derived from the upstream image's
                         org.opencontainers.image.version label, else "latest").
  --registry REG         Registry prefix used when pushing
                         (default: ghcr.io/candlepin).
  --no-latest            Do not also tag/push the ":latest" tag.
  --no-test              Skip the post-build smoke test.
  --no-pod               Do not start the candlepin pod from the built images.
  --push                 Push the built images to --registry (requires login).
  --keep                 Keep provisioning containers/network on exit (for debugging).
  -h, --help             Show this help.

Examples:
  ./build.sh                                   # build + test, no push
  ./build.sh --deployment-dir ../candlepin/bin/deployment
  ./build.sh --push --registry ghcr.io/myuser  # build + test + push
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream-image)  UPSTREAM_IMAGE="$2"; shift 2 ;;
    --httpd-image)     HTTPD_IMAGE="$2"; shift 2 ;;
    --candlepin-ref)   CANDLEPIN_REF="$2"; shift 2 ;;
    --deployment-dir)  DEPLOYMENT_DIR="$2"; shift 2 ;;
    --tag)             TAG="$2"; shift 2 ;;
    --registry)        REGISTRY="$2"; shift 2 ;;
    --no-latest)       UPDATE_LATEST=0; shift ;;
    --no-test)         RUN_TEST=0; shift ;;
    --no-pod)          CREATE_POD=0; shift ;;
    --push)            DO_PUSH=1; shift ;;
    --keep)            KEEP=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "Unknown option: $1 (try --help)" ;;
  esac
done

command -v podman >/dev/null || die "podman is not installed"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
# Records the line/command that tripped `set -e` so cleanup can report it.
FAILED_LINE=""
FAILED_CMD=""
on_error() {
  FAILED_LINE="$1"
  FAILED_CMD="$2"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "build.sh exited with code $rc"
    [ -n "$FAILED_LINE" ] && warn "  failing command (line $FAILED_LINE): $FAILED_CMD"
  fi
  if [ "$KEEP" -eq 1 ]; then
    warn "--keep set: leaving provisioning containers and network in place"
    warn "  containers: $DB_C $APP_C $REPO_C   network: $NET"
    return "$rc"
  fi
  log "Cleaning up provisioning containers and network"
  podman rm -f "$APP_C" "$REPO_C" "$DB_C" >/dev/null 2>&1 || true
  podman rm -f "$TEST_APP_C" "$TEST_REPO_C" "$TEST_DB_C" "$TEST_PROXY_C" >/dev/null 2>&1 || true
  rm -rf "$SCRIPT_DIR/proxy/certs" >/dev/null 2>&1 || true
  podman network rm -f "$NET" "$TEST_NET" >/dev/null 2>&1 || true
  podman rmi -f "${DB_IMAGE_NAME}:base" >/dev/null 2>&1 || true
  [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
  # Propagate the status the script was exiting with; a failing command above
  # (e.g. the "[ -n ... ] &&" when no temp dir was created) must not mask it.
  return "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Resolve the test-data scripts directory
# ---------------------------------------------------------------------------
resolve_deployment_dir() {
  if [ -n "$DEPLOYMENT_DIR" ]; then
    [ -d "$DEPLOYMENT_DIR" ] || die "--deployment-dir '$DEPLOYMENT_DIR' does not exist"
    log "Using test-data scripts from $DEPLOYMENT_DIR"
  else
    command -v git >/dev/null || die "git is required to clone candlepin (or use --deployment-dir)"
    TMP_DIR="$(mktemp -d)"
    log "Cloning candlepin@${CANDLEPIN_REF} (sparse: bin/deployment)"
    git clone --quiet --depth 1 --branch "$CANDLEPIN_REF" \
      --filter=blob:none --sparse \
      https://github.com/candlepin/candlepin.git "$TMP_DIR/candlepin.git"
    git -C "$TMP_DIR/candlepin.git" sparse-checkout set bin/deployment >/dev/null
    DEPLOYMENT_DIR="$TMP_DIR/candlepin.git/bin/deployment"
  fi
  for f in test_data_importer.py test_data.json create_test_repos.py deploy_pkg; do
    [ -e "$DEPLOYMENT_DIR/$f" ] || die "missing $f in $DEPLOYMENT_DIR"
  done
}

# ---------------------------------------------------------------------------
# Determine image tag
# ---------------------------------------------------------------------------
determine_tag() {
  if [ -n "$TAG" ]; then
    return
  fi
  TAG="$(podman inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
    "$UPSTREAM_IMAGE" 2>/dev/null || true)"
  TAG="$(echo "$TAG" | sed 's,/,-,g' | tr '[:upper:]' '[:lower:]')"
  [ -n "$TAG" ] || TAG="latest"
  log "Image tag: $TAG"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
build() {
  log "Pulling upstream image: $UPSTREAM_IMAGE"
  podman pull "$UPSTREAM_IMAGE"

  determine_tag

  log "Building candlepin-db base image"
  podman build -f "$SCRIPT_DIR/Containerfile.db" -t "${DB_IMAGE_NAME}:base" "$SCRIPT_DIR"

  # Start from a clean slate for the build-scoped names.
  podman rm -f "$APP_C" "$REPO_C" "$DB_C" >/dev/null 2>&1 || true
  podman network rm -f "$NET" >/dev/null 2>&1 || true

  log "Creating provisioning network: $NET"
  podman network create "$NET" >/dev/null

  log "Starting DB container (alias: $DB_ALIAS)"
  podman run -d --network "${NET}:alias=${DB_ALIAS}" --name "$DB_C" \
    "${DB_IMAGE_NAME}:base" >/dev/null

  log "Starting app container"
  podman run -d --network "$NET" --name "$APP_C" \
    --entrypoint '["sh", "-c", "/opt/tomcat/bin/catalina.sh run"]' \
    "$UPSTREAM_IMAGE" >/dev/null

  log "Copying test data and provisioning script into app container"
  podman exec --user root "$APP_C" mkdir -p /opt/test-data
  podman cp "$DEPLOYMENT_DIR/test_data_importer.py" "$APP_C:/opt/test-data/"
  podman cp "$DEPLOYMENT_DIR/test_data.json"        "$APP_C:/opt/test-data/"
  podman cp "$DEPLOYMENT_DIR/create_test_repos.py"  "$APP_C:/opt/test-data/"
  podman cp "$DEPLOYMENT_DIR/deploy_pkg"            "$APP_C:/opt/test-data/deploy_pkg"
  podman cp "$SCRIPT_DIR/provision.sh"              "$APP_C:/opt/provision.sh"
  podman exec --user root "$APP_C" chmod +x /opt/provision.sh

  log "Provision: install dependencies"
  podman exec --user root "$APP_C" /opt/provision.sh install-deps

  log "Provision: wait for Candlepin API"
  podman logs -f "$APP_C" &
  local logs_pid=$!
  timeout 600 podman exec --user root "$APP_C" /opt/provision.sh wait-api
  kill "$logs_pid" >/dev/null 2>&1 || true

  log "Provision: validate required files"
  podman exec --user root "$APP_C" /opt/provision.sh validate

  log "Provision: import test data"
  timeout 240 podman exec --user root "$APP_C" /opt/provision.sh import-data

  log "Provision: create test RPM repos"
  timeout 120 podman exec --user root "$APP_C" /opt/provision.sh create-repos

  log "Starting repo container"
  podman run -d --name "$REPO_C" "$HTTPD_IMAGE" >/dev/null

  log "Copying generated repos into repo container"
  # create_test_repos.py writes the repos into Tomcat's ROOT webapp; the
  # hummingbird httpd image serves /var/www/html (HTTP on 9080, HTTPS on 9443
  # after the reconfiguration below).
  podman cp "$APP_C:/var/lib/tomcat/webapps/ROOT/." "$REPO_C:/var/www/html/"

  # Relocate the repo's listeners off the default 8080/8443 so it never shares a
  # port with candlepin-app (which uses 8443) inside the shared pod namespace:
  # HTTP -> 9080, HTTPS -> 9443. The stock image also gates its SSL vhost behind
  # <IfFile /etc/pki/tls/certs/localhost.crt> (absent by default, so HTTPS never
  # binds), so we install candlepin's own TLS cert (below) to activate it.
  log "Reconfiguring repo httpd listeners (http:9080, https:9443)"
  local httpd_cfg
  httpd_cfg="$(mktemp -d)"

  podman cp "$REPO_C:/etc/httpd/conf/httpd.conf" "$httpd_cfg/httpd.conf"
  sed -i 's/^Listen 8080$/Listen 9080/' "$httpd_cfg/httpd.conf"
  podman cp "$httpd_cfg/httpd.conf" "$REPO_C:/etc/httpd/conf/httpd.conf"

  podman cp "$REPO_C:/etc/httpd/conf.d/ssl.conf" "$httpd_cfg/ssl.conf"
  sed -i -e 's/^Listen 8443 https$/Listen 9443 https/' \
         -e 's/<VirtualHost _default_:8443>/<VirtualHost _default_:9443>/' \
         "$httpd_cfg/ssl.conf"
  podman cp "$httpd_cfg/ssl.conf" "$REPO_C:/etc/httpd/conf.d/ssl.conf"

  # Present candlepin-app's own TLS certificate so both services are reachable at
  # https://candlepin (only the port differs) and validate against the same CA.
  # candlepin-app uses its self-signed RSA "Server CA" cert directly as the TLS
  # server cert (see server.xml SSLHostConfig); that cert carries SAN DNS:candlepin
  # and is included in candlepin-ca-bundle.crt, so any client trusting the bundle
  # trusts the repo too. We copy it to the paths the stock ssl.conf expects.
  # Mode 0644 so the apache user (the image's default USER) can read the key.
  podman cp "$APP_C:/etc/candlepin/certs/candlepin-rsa-ca.crt" "$httpd_cfg/localhost.crt"
  podman cp "$APP_C:/etc/candlepin/certs/candlepin-rsa-ca.key" "$httpd_cfg/localhost.key"
  chmod 0644 "$httpd_cfg/localhost.key" "$httpd_cfg/localhost.crt"
  podman cp "$httpd_cfg/localhost.crt" "$REPO_C:/etc/pki/tls/certs/localhost.crt"
  podman cp "$httpd_cfg/localhost.key" "$REPO_C:/etc/pki/tls/private/localhost.key"
  # The CA bundle, so the repo can serve the same trust anchor candlepin publishes.
  podman cp "$APP_C:/etc/candlepin/certs/candlepin-ca-bundle.crt" \
    "$REPO_C:/etc/pki/tls/certs/candlepin-ca-bundle.crt"

  rm -rf "$httpd_cfg"

  log "Provision: copy generated certs"
  podman exec --user root "$APP_C" /opt/provision.sh copy-certs

  log "Provision: cleanup"
  podman exec --user root "$APP_C" /opt/provision.sh cleanup

  # Enable reverse-proxy TLS termination support in Tomcat. The candlepin-proxy
  # (nginx) container terminates the client's TLS connection with an RSA cert and
  # forwards requests to candlepin over plain HTTP (8080). This sidesteps a Go
  # 1.27+ regression: Go advertises ML-DSA in signature_algorithms but omits it
  # from signature_algorithms_cert, so when Tomcat's OpenSSL provider selects the
  # ML-DSA server cert (candlepin offers both ML-DSA and RSA) the handshake fails
  # with "no suitable signature algorithm". nginx only ever presents the RSA cert.
  #
  # To keep candlepin's mutual-TLS auth working through the proxy, SSLValve turns
  # the forwarded ssl_client_escaped_cert header back into the
  # jakarta.servlet.request.X509Certificate attribute that candlepin's SSLAuth
  # reads, and RemoteIpValve restores the https scheme from X-Forwarded-Proto.
  log "Provision: configure server.xml for reverse proxy (valves + move TLS to 8444)"
  podman exec --user root "$APP_C" python3 - <<'PY'
import re, sys

path = "/opt/tomcat/conf/server.xml"
with open(path) as f:
    xml = f.read()

changed = False

# 1) Move candlepin's own HTTPS connector off the public port 8443 to an internal
#    port 8444, so the candlepin-proxy (nginx) can own 8443. The proxy forwards to
#    candlepin over plain HTTP (8080); the 8444 TLS connector (with both the RSA
#    and ML-DSA certs) stays available for direct access and debugging.
if 'port="8443"' in xml:
    xml = xml.replace('port="8443"', 'port="8444"', 1)
    changed = True
# Keep the HTTP connector's redirectPort consistent with the moved TLS port.
if 'redirectPort="8443"' in xml:
    xml = xml.replace('redirectPort="8443"', 'redirectPort="8444"')
    changed = True

# 2) Add RemoteIpValve + SSLValve so candlepin still sees the request as HTTPS and
#    can read the client certificate the proxy forwards (as ssl_client_escaped_cert).
if "org.apache.catalina.valves.SSLValve" not in xml:
    access_valve = '<Valve className="org.apache.catalina.valves.AccessLogValve"'
    if access_valve not in xml:
        sys.exit("server.xml: could not find AccessLogValve to anchor the insertion")
    valves = (
        '<Valve className="org.apache.catalina.valves.RemoteIpValve"\n'
        '               protocolHeader="X-Forwarded-Proto"\n'
        '               internalProxies=".*" />\n'
        '        <Valve className="org.apache.catalina.valves.SSLValve" />\n'
        '        '
    )
    xml = xml.replace(access_valve, valves + access_valve, 1)
    changed = True

if not changed:
    print("server.xml: already configured for reverse proxy, nothing to do")
    sys.exit(0)

with open(path, "w") as f:
    f.write(xml)
print("server.xml: TLS connector moved to 8444 and reverse-proxy valves added")
PY

  log "Building candlepin-proxy image (nginx TLS terminator)"
  # Stage the certs the proxy needs (RSA server cert/key for TLS termination and
  # the CA bundle for client-cert verification) from the provisioned app
  # container into the proxy build context, then build the image.
  local proxy_ctx="$SCRIPT_DIR/proxy"
  mkdir -p "$proxy_ctx/certs"
  podman cp "$APP_C:/etc/candlepin/certs/candlepin-rsa-ca.crt"    "$proxy_ctx/certs/candlepin-rsa-ca.crt"
  podman cp "$APP_C:/etc/candlepin/certs/candlepin-rsa-ca.key"    "$proxy_ctx/certs/candlepin-rsa-ca.key"
  podman cp "$APP_C:/etc/candlepin/certs/candlepin-ca-bundle.crt" "$proxy_ctx/certs/candlepin-ca-bundle.crt"
  podman build -f "$proxy_ctx/Containerfile" -t "${PROXY_IMAGE_NAME}:${TAG}" "$proxy_ctx"
  rm -rf "$proxy_ctx/certs"

  log "Stopping containers gracefully"
  podman exec --user root "$APP_C" /opt/tomcat/bin/shutdown.sh 2>/dev/null || true
  sleep 5
  podman stop "$DB_C"; sleep 1
  podman stop "$REPO_C"; sleep 3

  log "Committing provisioned images (tag: $TAG)"
  podman commit \
    --change='USER tomcat' \
    --change='WORKDIR /opt/tomcat/bin' \
    --change='ENTRYPOINT ["sh", "-c", "rm -rf /opt/tomcat/webapps/candlepin && /opt/tomcat/bin/catalina.sh run"]' \
    --change='EXPOSE 8080 8444' \
    "$APP_C" "${APP_IMAGE_NAME}:${TAG}"

  podman commit \
    --change='EXPOSE 9080 9443' \
    "$REPO_C" "${REPO_IMAGE_NAME}:${TAG}"

  podman commit \
    --change='USER postgres' \
    --change='ENV PGDATA=/tmp/pgdata' \
    --change='CMD ["postgres"]' \
    --change='EXPOSE 5432' \
    "$DB_C" "${DB_IMAGE_NAME}:${TAG}"

  if [ "$UPDATE_LATEST" -eq 1 ] && [ "$TAG" != "latest" ]; then
    log "Tagging :latest"
    podman tag "${APP_IMAGE_NAME}:${TAG}"   "${APP_IMAGE_NAME}:latest"
    podman tag "${REPO_IMAGE_NAME}:${TAG}"  "${REPO_IMAGE_NAME}:latest"
    podman tag "${DB_IMAGE_NAME}:${TAG}"    "${DB_IMAGE_NAME}:latest"
    podman tag "${PROXY_IMAGE_NAME}:${TAG}" "${PROXY_IMAGE_NAME}:latest"
  fi
}

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
teardown_test() {
  podman rm -f "$TEST_APP_C" "$TEST_REPO_C" "$TEST_DB_C" "$TEST_PROXY_C" >/dev/null 2>&1 || true
  podman network rm -f "$TEST_NET" >/dev/null 2>&1 || true
}

# Run curl inside the app container so the smoke test stays entirely on
# $TEST_NET and never binds (and possibly conflicts with) host ports.
smoke_curl() {
  podman exec "$TEST_APP_C" curl "$@"
}

smoke_test() {
  log "Smoke-testing the built images"
  teardown_test
  podman network create "$TEST_NET" >/dev/null

  podman run -d --network "${TEST_NET}:alias=${DB_ALIAS}" --name "$TEST_DB_C" \
    "${DB_IMAGE_NAME}:${TAG}" >/dev/null
  podman run -d --network "$TEST_NET" --name "$TEST_REPO_C" \
    "${REPO_IMAGE_NAME}:${TAG}" >/dev/null
  podman run -d --network "$TEST_NET" --name "$TEST_APP_C" \
    "${APP_IMAGE_NAME}:${TAG}" >/dev/null
  # Run the proxy in the app container's network namespace so it reaches
  # candlepin on localhost:8080, mirroring the shared-namespace pod layout.
  podman run -d --network "container:${TEST_APP_C}" --name "$TEST_PROXY_C" \
    "${PROXY_IMAGE_NAME}:${TAG}" >/dev/null

  log "Waiting for Candlepin to come up..."
  local ready=0 i
  for i in $(seq 1 60); do
    if smoke_curl -sf -k https://localhost:8443/candlepin/status >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 5
  done
  if [ "$ready" -ne 1 ]; then
    podman logs "$TEST_APP_C" 2>&1 | tail -50
    die "Candlepin failed to start during smoke test"
  fi

  # The proxy listens on 8443 in the same namespace; the status/owners checks above
  # and below go through it (smoke_curl runs inside the app container).
  smoke_curl -sk https://localhost:8443/candlepin/status | python3 -m json.tool
  smoke_curl -sfk -u admin:admin https://localhost:8443/candlepin/owners >/dev/null \
    || die "owners endpoint check failed"
  smoke_curl --head -sf "http://${TEST_REPO_C}:9080/RPM-GPG-KEY-candlepin" >/dev/null \
    || die "GPG key check failed"
  smoke_curl --head -sf "http://${TEST_REPO_C}:9080/path/to/fake-content/38072-3902/repodata/repomd.xml" >/dev/null \
    || die "repo metadata check failed"
  smoke_curl --head -sf "http://${TEST_REPO_C}:9080/donaldduck/path/to/fake-content/38072-3902/repodata/repomd.xml" >/dev/null \
    || die "owner repo metadata check failed"
  smoke_curl --head -sf \
    --cacert /etc/candlepin/certs/candlepin-ca-bundle.crt \
    --connect-to "candlepin:9443:${TEST_REPO_C}:9443" \
    "https://candlepin:9443/RPM-GPG-KEY-candlepin" >/dev/null \
    || die "repo HTTPS (9443) check failed"
  log "Smoke test passed"

  teardown_test
}

# ---------------------------------------------------------------------------
# Push
# ---------------------------------------------------------------------------
push_images() {
  log "Pushing images to $REGISTRY"
  local img
  for img in "$APP_IMAGE_NAME" "$REPO_IMAGE_NAME" "$DB_IMAGE_NAME" "$PROXY_IMAGE_NAME"; do
    podman push "${img}:${TAG}" "${REGISTRY}/${img}:${TAG}"
    if [ "$UPDATE_LATEST" -eq 1 ] && [ "$TAG" != "latest" ]; then
      podman push "${img}:latest" "${REGISTRY}/${img}:latest"
    fi
  done
}

# ---------------------------------------------------------------------------
# Pod
# ---------------------------------------------------------------------------
create_pod() {
  [ -f "$POD_FILE" ] || die "pod file not found: $POD_FILE"

  log "Starting the '$POD_NAME' pod from the built images"

  # candlepin-pod.yaml references the published ghcr.io images; rewrite those
  # to the images we just built locally so the pod uses them.
  local pod_yaml
  pod_yaml="$(mktemp)"
  sed \
    -e "s,ghcr.io/candlepin/${DB_IMAGE_NAME}:latest,${DB_IMAGE_NAME}:${TAG}," \
    -e "s,ghcr.io/candlepin/${APP_IMAGE_NAME}:latest,${APP_IMAGE_NAME}:${TAG}," \
    -e "s,ghcr.io/candlepin/${REPO_IMAGE_NAME}:latest,${REPO_IMAGE_NAME}:${TAG}," \
    -e "s,ghcr.io/candlepin/${PROXY_IMAGE_NAME}:latest,${PROXY_IMAGE_NAME}:${TAG}," \
    "$POD_FILE" > "$pod_yaml"

  # Tear down any previous instance of the pod before (re)creating it.
  podman play kube "$pod_yaml" --down >/dev/null 2>&1 || true
  podman play kube "$pod_yaml"
  rm -f "$pod_yaml"

  log "Pod '$POD_NAME' started. Stop it with:"
  echo "  podman play kube $POD_FILE --down"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
resolve_deployment_dir
build
[ "$RUN_TEST" -eq 1 ] && smoke_test
[ "$DO_PUSH" -eq 1 ] && push_images
[ "$CREATE_POD" -eq 1 ] && create_pod

log "Done. Built images:"
echo "  ${APP_IMAGE_NAME}:${TAG}"
echo "  ${REPO_IMAGE_NAME}:${TAG}"
echo "  ${DB_IMAGE_NAME}:${TAG}"
echo "  ${PROXY_IMAGE_NAME}:${TAG}"
if [ "$UPDATE_LATEST" -eq 1 ] && [ "$TAG" != "latest" ]; then
  echo "  (also tagged :latest)"
fi
