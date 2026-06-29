# Candlepin Test Containers

Pre-provisioned [Candlepin](https://github.com/candlepin/candlepin) test
containers built on top of the
[official upstream image](https://quay.io/repository/candlepin/candlepin).
These images layer test data, yum repos, and certificates onto the upstream
`dev-latest` image so you can start testing immediately.

| Image | Base | Purpose |
|-------|------|---------|
| **candlepin-app** | `quay.io/candlepin/candlepin:dev-latest` | Candlepin API + pre-baked test data and yum repos |
| **candlepin-db** | Red Hat Hummingbird PostgreSQL | PostgreSQL with pre-baked schema and test data |

## Quick Start

```bash
podman network create candlepin-net

podman run -d --network candlepin-net --name postgres \
  ghcr.io/candlepin/candlepin-db:latest

podman run -d --network candlepin-net --name candlepin \
  -p 8443:8443 -p 8080:8080 \
  ghcr.io/candlepin/candlepin-app:latest

# Verify (wait ~30s for startup)
curl -sk https://localhost:8443/candlepin/status | python3 -m json.tool
```

The database container **must** be named `postgres` — the upstream
Candlepin image has `db_host=postgres` baked into its configuration.

## TLS Certificate Trust

To make the system trust Candlepin's TLS certificate:

```console
$ podman cp candlepin:/etc/candlepin/certs/candlepin-ca.crt . && \
  sudo mv ./candlepin-ca.crt /etc/rhsm/ca/candlepin-ca.pem
$ sudo ln -s /etc/rhsm/ca/candlepin-ca.pem \
  /etc/pki/ca-trust/source/anchors/candlepin-ca.pem
$ sudo update-ca-trust
$ sudo chown root:root /etc/rhsm/ca/candlepin-ca.pem
$ sudo restorecon -v /etc/rhsm/ca/candlepin-ca.pem
$ curl https://127.0.0.1:8443/candlepin/status
```

## Subscription Manager Configuration

Add the container to your system's DNS and configure subscription-manager:

```console
$ sudo echo '127.0.0.1 candlepin.local' >> /etc/hosts
$ curl https://candlepin.local:8443/candlepin/status
$ sudo subscription-manager config \
  --server.hostname candlepin.local \
  --server.port 8443 \
  --server.prefix /candlepin \
  --rhsm.baseurl http://candlepin.local:8080
```

To install packages from the test RPM repository, import the GPG key:

```console
$ sudo curl http://candlepin.local:8080/RPM-GPG-KEY-candlepin > /etc/pki/rpm-gpg/RPM-GPG-KEY-candlepin
```

## GitHub Actions Services

```yaml
services:
  postgres:
    image: ghcr.io/candlepin/candlepin-db:latest
  candlepin:
    image: ghcr.io/candlepin/candlepin-app:latest
    options: --hostname candlepin.local
    ports:
      - 8443:8443
      - 8080:8080
```

## What These Images Add

The official `quay.io/candlepin/candlepin:dev-latest` image starts with an
empty database. These images layer pre-provisioned test data on top:

- **Owners**: `admin`, `donaldduck`, `snowwhite`, and others from
  `test_data.json`
- **Products, subscriptions, and pools** for all owners
- **Yum repos** with installable test RPMs (`slow-eagle`, `tricky-frog`,
  `awesome-rabbit`, etc.) served via Tomcat on port 8080
- **RPM GPG key** at `http://candlepin:8080/RPM-GPG-KEY-candlepin`
- **Generated product certificates** embedded in repo metadata

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 8443 | HTTPS | Candlepin API |
| 8080 | HTTP | Candlepin API + test yum repos |
| 5432 | TCP | PostgreSQL |

## Test Accounts

The images contain [various accounts](https://github.com/candlepin/candlepin/blob/47778198d0be21cd297c40a322024d6c2f1b8408/bin/deployment/test_data.json) that can be used for testing:

| user      | password | organizations                         |
|-----------|----------|---------------------------------------|
| testuser1 | password | admin, snowwhite                      |
| testuser2 | password | admin                                 |
| testuser3 | password | admin-ro                              |
| doc       | password | admin, snowwhite, donaldduck          |
| grumpy    | password | snowwhite                             |
| sleepy    | password | snowwhite-ro                          |
| bashful   | password | snowwhite-ro                          |
| sneezy    | password | snowwhite-ro                          |
| dopey     | password | snowwhite-ro                          |
| huey      | password | admin, snowwhite, donaldduck          |
| duey      | password | donaldduck                            |
| louie     | password | donaldduck-ro                         |
| mickey    | password | donaldduck, snowwhite-ro              |
| minnie    | password | snowwhite, donaldduck-ro              |
| magoo     | password | donaldduck-ro, snowwhite-ro, admin-ro |

| organizations | entitlement mode | SCA mode |
|---------------|-----|-----|
| admin         | yes |     |
| donaldduck    |     | yes |
| snowwhite     | yes |     |

## Building

The GitHub Actions workflow (`split_image_build.yml`) pulls the official
upstream image, provisions test data at build time, and commits the result:

1. Pull `quay.io/candlepin/candlepin:dev-latest`
2. Build `candlepin-db` from `split/Containerfile.db`
3. Boot both on a shared network
4. Run `provision.sh` (imports test data, creates yum repos)
5. Commit both containers
6. Test the committed images
7. Push to `ghcr.io/candlepin/`

> **Warning**: Default credentials (`admin:admin`, `candlepin:candlepin`)
> are for testing only.

---

## Legacy Monolithic Image (Candlepin <= 4.7)

> **Note**: The monolithic image below is maintained for testing against
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
$ ansible-galaxy collection install --force -r requirements.yml
$ buildah build -t cp_base
$ podman run --name=candlepin --hostname=candlepin.local --publish=8443:8443 --publish=8080:8080 \
    --publish=2222:22 --privileged --detach -t cp_base
$ ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory -v playbook.yml
$ podman exec candlepin poweroff
$ podman start candlepin
```

Build files: `Containerfile`, `playbook.yml`, `.github/workflows/image_build.yml`
