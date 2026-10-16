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

podman run -d --network candlepin-net --name candlepin \
  -p 8443:8443 \
  ghcr.io/candlepin/candlepin-app:latest

podman run -d --network candlepin-net --name candlepin-repo \
  -p 8080:8080 \
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

Then copy the CA certificate and update the trust store:

```console
$ podman cp candlepin:/etc/candlepin/certs/candlepin-ca-bundle.crt . && \
  sudo mv ./candlepin-ca-bundle.crt /etc/rhsm/ca/candlepin-ca-bundle.pem
$ sudo ln -s /etc/rhsm/ca/candlepin-ca-bundle.pem \
  /etc/pki/ca-trust/source/anchors/candlepin-ca-bundle.pem
$ sudo update-ca-trust
$ sudo chown root:root /etc/rhsm/ca/candlepin-ca-bundle.pem
$ sudo restorecon -v /etc/rhsm/ca/candlepin-ca-bundle.pem
$ curl https://candlepin:8443/candlepin/status
```

Configure subscription-manager to use the container:

```console
$ sudo subscription-manager config \
  --server.hostname candlepin \
  --server.port 8443 \
  --server.prefix /candlepin \
  --rhsm.baseurl http://candlepin:8080
```

To install packages from the test RPM repository, import the GPG key:

```console
$ sudo curl -o /etc/pki/rpm-gpg/RPM-GPG-KEY-candlepin http://candlepin:8080/RPM-GPG-KEY-candlepin
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

The GitHub Actions workflow (`image_build.yml`) pulls the official
upstream image, provisions test data at build time, and commits the result:

1. Pull `quay.io/candlepin/candlepin:dev-latest`
2. Build `candlepin-db` from `Containerfile.db`
3. Boot both on a shared network
4. Run `provision.sh` (imports test data, create repos)
5. Create `candlepin-repo` container with test yum repos
6. Commit all containers
7. Test the committed images
8. Push to `ghcr.io/candlepin/`

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