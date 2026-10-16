# Candlepin Test Containers

Pre-provisioned [Candlepin](https://github.com/candlepin/candlepin) test containers built on top of the
[official upstream image](https://quay.io/repository/candlepin/candlepin). These containers are
intended for testing only purpose. It could be used for testing client applications.
Testing data like user credentials, products, testing repositories and testing RPMs
could change over time. These images layer test data and certificates onto the upstream
`dev-latest` image so you can start testing immediately.

| Image              | Base | Purpose |
|--------------------|------|---------|
| **candlepin-app**  | `quay.io/candlepin/candlepin:dev-latest` | Candlepin API + pre-baked test data and yum repos |
| **candlepin-repo** | Red Hat Hummingbird Apache | Apache server providing testing yum repository |
| **candlepin-db**   | Red Hat Hummingbird PostgreSQL | PostgreSQL with pre-baked schema and test data |

## Quick Start: Pod

The simplest way to run all containers — a single command, no manual
network setup:

```bash
podman play kube candlepin-pod.yaml

# Verify (wait ~30s for startup)
curl -sk https://localhost:8443/candlepin/status | python3 -m json.tool

# Tear down
podman play kube candlepin-pod.yaml --down
```

The pod YAML sets two environment variables that override `db_host=postgres`
in `candlepin.conf` so Candlepin connects to PostgreSQL over `localhost`
(the shared pod network namespace). See "Overriding the database hostname"
in the `INSTALL.md` file.

## Configure host

When you want to use candlepin pod for testing on your machine, then it is recommended to run bash
script provided in this repository:

```console
$ ./configure-host.sh
```

## GitHub Actions Services

GitHub Actions services use Docker networking (not pods), so the DB
service must be named `postgres`:

```yaml
services:
  postgres:
    image: ghcr.io/candlepin/candlepin-db:latest
  candlepin:
    image: ghcr.io/candlepin/candlepin-app:latest
    options: --hostname candlepin
    ports:
      - 8443:8443
  candlepin-repo:
    image: ghcr.io/candlepin/candlepin-repo:latest
    ports:
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
