# Candlepin Test Containers

Pre-provisioned [Candlepin](https://github.com/candlepin/candlepin) test containers built on top of the
[official upstream image](https://quay.io/repository/candlepin/candlepin). These containers are
intended for testing only purpose. It could be used for testing client applications.
Testing data like user credentials, products, testing repositories and testing RPMs
could change over time. These images layer test data and certificates onto the upstream
`dev-latest` image so you can start testing immediately.

| Image               | Base | Purpose |
|---------------------|------|---------|
| **candlepin-app**   | `quay.io/candlepin/candlepin:dev-latest` | Candlepin API + pre-baked test data and yum repos |
| **candlepin-proxy** | Red Hat Hummingbird nginx | TLS-terminating reverse proxy in front of candlepin-app (public HTTPS on 8443) |
| **candlepin-repo**  | Red Hat Hummingbird Apache | Apache server providing testing yum repository |
| **candlepin-db**    | Red Hat Hummingbird PostgreSQL | PostgreSQL with pre-baked schema and test data |

> **Why a proxy?** candlepin-app offers both an ML-DSA (post-quantum) and an RSA
> TLS server certificate. Go 1.27+ clients advertise ML-DSA in the TLS 1.3
> `signature_algorithms` extension but omit it from `signature_algorithms_cert`,
> so when the server selects the ML-DSA certificate the handshake fails with
> *"no suitable signature algorithm"*. `candlepin-proxy` terminates TLS with a
> plain RSA certificate (so those clients connect), then forwards requests to
> candlepin over HTTP while still passing the client certificate through, so
> mutual-TLS authentication keeps working. This also mirrors how Candlepin is
> typically fronted by a web server in production.

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

When you want to use the candlepin pod for testing on your machine, run the helper script:

```console
$ ./configure-host.sh
$ ./configure-host.sh --help   # show options
$ ./configure-host.sh my-app-container   # custom container name
```

The script runs as a regular user (not via `sudo`; privileged steps use `sudo` internally) and:

1. Adds `127.0.0.1 candlepin` to `/etc/hosts`
2. Installs Candlepin's CA bundle to `/etc/rhsm/ca` and the system trust store (`/etc/pki/ca-trust`)
3. Configures `subscription-manager` to use `candlepin:8443/candlepin` and `https://candlepin:9443` for repos
4. Imports the test RPM GPG key to `/etc/pki/rpm-gpg`

Before overwriting `subscription-manager` settings, the current values for `server.hostname`, `server.port`, `server.prefix`, `rhsm.baseurl` and `rhsm.repo_ca_cert` are saved to a per-user backup file. By default this is `${XDG_STATE_HOME:-$HOME/.local/state}/candlepin-test/subscription-manager.conf.bak` (e.g. `~/.local/state/candlepin-test/subscription-manager.conf.bak`). The file records each value and whether it was a default (`[]` in `subscription-manager config --list`).

To revert all changes:

```console
$ ./restore-host.sh              # undo all 4 steps
$ ./restore-host.sh --help
$ ./restore-host.sh --keep-subman --keep-ca-cert   # keep subman and CA, restore rest
```

`restore-host.sh` restores the previous `subscription-manager` configuration from the backup, verifies the result with `subscription-manager config --list`, and removes the backup on success. If no backup exists it reports the location searched and leaves the current configuration untouched (use `subscription-manager config --remove` manually to reset to Red Hat defaults). Each step can be skipped individually with `--keep-etc-hosts`, `--keep-ca-cert`, `--keep-subman`, `--keep-gpg-key`; the script is idempotent.

Environment variables:

- `CANDLEPIN_TEST_STATE_DIR` — directory for `subscription-manager.conf.bak`; defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/candlepin-test`. Set the same value for both scripts to use a custom location, e.g. `CANDLEPIN_TEST_STATE_DIR=/tmp/my-backup ./configure-host.sh`. A legacy path `/var/lib/candlepin-test/subscription-manager.conf.bak` is checked by `restore-host.sh` for backward compatibility.

## Building the Images Locally

All four images can be built with a single command:

```console
$ ./build.sh
```

This pulls the upstream Candlepin image, boots a throwaway PostgreSQL + app
pair, imports the test data, bakes the yum repositories, commits the four
images (`candlepin-app`, `candlepin-proxy`, `candlepin-repo`, `candlepin-db`),
runs a smoke test against them, and finally starts the `candlepin` pod from the
freshly built images. Pass `--no-pod` to skip starting the pod.

By default the test-data scripts are fetched by cloning
[candlepin](https://github.com/candlepin/candlepin) (`main`). Common options:

```console
$ ./build.sh --candlepin-ref 5.0                 # use a different candlepin ref
$ ./build.sh --deployment-dir ../candlepin/bin/deployment  # use a local checkout
$ ./build.sh --no-test                           # skip the smoke test
$ ./build.sh --no-pod                            # don't start the candlepin pod
$ ./build.sh --push --registry ghcr.io/myuser    # build, test, then push
```

Run `./build.sh --help` for the full list of options. The GitHub Actions
workflow (`.github/workflows/image_build.yml`) is a thin wrapper that simply
logs in and calls this script.

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
    # candlepin-app serves HTTP on 8080 (consumed by the proxy) and its own TLS
    # on the internal port 8444. The public HTTPS endpoint is candlepin-proxy.
  candlepin-proxy:
    image: ghcr.io/candlepin/candlepin-proxy:latest
    ports:
      - 8443:8443
  candlepin-repo:
    image: ghcr.io/candlepin/candlepin-repo:latest
    ports:
      - 9080:9080
      - 9443:9443
```

> Note: with Docker networking (not a shared pod namespace), candlepin-proxy
> reaches candlepin on `127.0.0.1:8080`, so run it in candlepin-app's network
> namespace (e.g. `--network container:candlepin`) or adjust `proxy/candlepin.conf`'s
> `proxy_pass` to the candlepin service name.

## What These Images Add

The official `quay.io/candlepin/candlepin:dev-latest` image starts with an
empty database. These images layer pre-provisioned test data on top:

- **Owners**: `admin`, `donaldduck`, `snowwhite`, and others from
  `test_data.json`
- **Products, subscriptions, and pools** for all owners
- **Yum repos** with installable test RPMs (`slow-eagle`, `tricky-frog`,
  `awesome-rabbit`, etc.) served by the repo container on port 9080 (HTTP)
  and 9443 (HTTPS). The HTTPS listener reuses candlepin-app's TLS certificate,
  so it validates against the same `candlepin-ca-bundle.crt` as the API.
- **RPM GPG key** at `http://candlepin:9080/RPM-GPG-KEY-candlepin`
- **Generated product certificates** embedded in repo metadata

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 8443 | HTTPS | Candlepin API (via candlepin-proxy) |
| 8444 | HTTPS | Candlepin API direct on candlepin-app (internal, not published) |
| 8080 | HTTP | candlepin-app for the proxy (internal, not published) |
| 9080 | HTTP | Test yum repos |
| 9443 | HTTPS | Test yum repos |
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
