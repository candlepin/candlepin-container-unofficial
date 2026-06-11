# Split Candlepin Containers

Pre-provisioned Candlepin test containers built on top of the
[official upstream image](https://quay.io/repository/candlepin/candlepin).

| Image | Base | Purpose |
|-------|------|---------|
| **candlepin-app** | `quay.io/candlepin/candlepin:dev-latest` | Official Candlepin + pre-baked test data and yum repos |
| **candlepin-db** | Red Hat Hummingbird PostgreSQL | PostgreSQL with pre-baked schema and test data |

## Quick Start (Podman)

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

The official `quay.io/candlepin/candlepin:dev-latest` image starts with
an empty database. These images layer pre-provisioned test data on top:

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
