# Installation

Many details about candlepin containers could be found in the [README](README.md) file.
This file contains more low level instructions and notes for developers.

## Quick Start: Network

Use a podman/docker network when you need named containers (e.g. GitHub
Actions services) or want to run the database separately:

```bash
podman network create candlepin-net

podman run -d --network candlepin-net --name postgres \
  ghcr.io/candlepin/candlepin-db:latest

# candlepin-app serves HTTP on 8080 (for the proxy) and its own TLS on the
# internal port 8444; it no longer publishes 8443 directly. candlepin-proxy
# shares this container's network namespace, so publish the public HTTPS port
# (8443) here, on the namespace owner.
podman run -d --network candlepin-net --name candlepin \
  -p 8443:8443 \
  ghcr.io/candlepin/candlepin-app:latest

# candlepin-proxy terminates public TLS on 8443 and forwards to candlepin-app
# over HTTP. It reaches candlepin on 127.0.0.1:8080 via the shared namespace
# (see proxy/candlepin.conf to point proxy_pass elsewhere).
podman run -d --network container:candlepin --name candlepin-proxy \
  ghcr.io/candlepin/candlepin-proxy:latest

podman run -d --network candlepin-net --name candlepin-repo \
  -p 9080:9080 \
  -p 9443:9443 \
  ghcr.io/candlepin/candlepin-repo:latest

# Verify (wait ~30s for startup)
curl -sk https://localhost:8443/candlepin/status | python3 -m json.tool
```

On a container network the DB container must be named `postgres` to match
the default `db_host` in `candlepin.conf`, unless you override it with
environment variables (see below).

### Manual configuration of the host

If you want to configure your host manually, then it is possible. You have to do following steps.

To make the system trust Candlepin's TLS certificate, first add the
container to your system's DNS so `candlepin` resolves:

```console
$ echo '127.0.0.1 candlepin' | sudo tee -a /etc/hosts
```

Then copy the CA certificates and update the trust store. candlepin-app (the
API) and candlepin-repo (the test yum repos) use **separate** CAs, so import
both. The repo CA lives inside the candlepin-repo container:

```console
$ podman cp candlepin:/etc/candlepin/certs/candlepin-ca-bundle.crt . && \
  sudo mv ./candlepin-ca-bundle.crt /etc/rhsm/ca/candlepin-ca-bundle.pem
$ podman cp candlepin-repo:/etc/pki/tls/certs/candlepin-repo-ca.crt . && \
  sudo mv ./candlepin-repo-ca.crt /etc/rhsm/ca/candlepin-repo-ca.pem
$ sudo ln -s /etc/rhsm/ca/candlepin-ca-bundle.pem \
  /etc/pki/ca-trust/source/anchors/candlepin-ca-bundle.pem
$ sudo ln -s /etc/rhsm/ca/candlepin-repo-ca.pem \
  /etc/pki/ca-trust/source/anchors/candlepin-repo-ca.pem
$ sudo update-ca-trust
$ sudo chown root:root /etc/rhsm/ca/candlepin-ca-bundle.pem /etc/rhsm/ca/candlepin-repo-ca.pem
$ sudo restorecon -v /etc/rhsm/ca/candlepin-ca-bundle.pem /etc/rhsm/ca/candlepin-repo-ca.pem
$ curl https://candlepin:8443/candlepin/status
```

Configure subscription-manager to use the container. `rhsm.repo_ca_cert`
accepts a single file, so point it at a candlepin-repo-ca:

```console
$ sudo subscription-manager config \
  --server.hostname candlepin \
  --server.port 8443 \
  --server.prefix /candlepin \
  --rhsm.baseurl https://candlepin:9443 \
  --rhsm.repo_ca_cert /etc/rhsm/ca/candlepin-repo-ca.pem
```

`repo_ca_cert` is written as `sslcacert` into the generated repo files, so
the test repos served over HTTPS validate against the repo CA in the candlepin-repo-ca.

To install packages from the test RPM repository, import the GPG key:

```console
$ sudo curl -o /etc/pki/rpm-gpg/RPM-GPG-KEY-candlepin https://candlepin:9443/RPM-GPG-KEY-candlepin
```

## Overriding the database hostname

Candlepin uses [SmallRye Config](https://smallrye.io/smallrye-config/)
with environment variables (ordinal 300) taking precedence over
`candlepin.conf` (ordinal 225). To point Candlepin at a different
database host, set these env vars on the app container:

| Config property | Env var | Default |
|-----------------|---------|---------|
| `jpa.config.hibernate.connection.url` | `JPA_CONFIG_HIBERNATE_CONNECTION_URL` | `jdbc:postgresql://postgres/candlepin` |
| `org.quartz.dataSource.myDS.URL` | `ORG_QUARTZ_DATASOURCE_MYDS_URL` | `jdbc:postgresql://postgres/candlepin` |

The pod YAML sets both to `jdbc:postgresql://localhost/candlepin`. The
upstream candlepin project uses the same mechanism in its own
[dev-container deployment](https://github.com/candlepin/candlepin/blob/main/dev-container/candlepin-deployment.yaml).

## Building

All four images are built by `build.sh` — see [Building the Images
Locally](README.md#building-the-images-locally) in the README for the available
options. The script pulls the official upstream image, provisions test data at
build time, and commits the result:

1. Pull `quay.io/candlepin/candlepin:dev-latest`
2. Build `candlepin-db` from `Containerfile.db`
3. Boot both on a shared network
4. Run `provision.sh` (imports test data, creates repos)
5. Create `candlepin-repo` container with test yum repos
6. Configure candlepin-app's `server.xml` for reverse-proxy TLS termination
   (move its TLS connector to 8444, add SSLValve/RemoteIpValve) and build
   `candlepin-proxy` from `proxy/Containerfile` with candlepin's RSA cert
7. Commit all containers
8. Smoke-test the committed images (on an internal network, no host ports)
9. Optionally push to `ghcr.io/candlepin/`

To build and test everything locally:

```console
$ ./build.sh
```

The GitHub Actions workflow (`image_build.yml`) is a thin wrapper around
`build.sh`: it logs in to ghcr.io and runs the script with the inputs chosen
in the workflow dispatch form.

> **Warning**: Default credentials (`admin:admin`, `candlepin:candlepin`)
> are for testing only.

---

## Legacy Monolithic Image (Candlepin <= 4.7)

> **Note**: The monolithic image below was maintained for testing against
> older Candlepin versions (4.7.x and earlier). For current Candlepin
> development, use the `candlepin-app` / `candlepin-db` images above.

The legacy `candlepin-unofficial` image is a single all-in-one container
(CentOS Stream 9, Java 17, systemd, embedded PostgreSQL) that builds
Candlepin from source using Ansible.

```console
$ podman run -d --name candlepin -p 8080:8080 \
  --pull newer ghcr.io/candlepin/candlepin-unofficial:latest
```

To build locally:

```console
$ ansible-galaxy collection install --force -r legacy/requirements.yml
$ buildah build -f legacy/Containerfile -t cp_base
$ podman run --name=candlepin --hostname=candlepin.local --publish=8443:8443 --publish=8080:8080 \
    --publish=2222:22 --privileged --detach -t cp_base
$ ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i legacy/inventory -v legacy/playbook.yml
$ podman exec candlepin poweroff
$ podman start candlepin
```

Build files: `legacy/Containerfile`, `legacy/playbook.yml`, `.github/workflows/legacy_image_build.yml`