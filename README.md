# Unofficial Candlepin container

[Candlepin](https://github.com/candlepin/candlepin) is a server that [subscription-manager](https://github.com/candlepin/subscription-manager) talks to when it performs registration or fact collection. This repository manages its unofficial container image the developers can use for testing.

To start the container, run

```console
$ podman run -d --name candlepin -p 8080:8080 \
  --pull newer ghcr.io/candlepin/candlepin-unofficial:latest
```

To start the container with TLS certificates, run

```console
$ podman run -d --name candlepin \
  -p 8080:8080 -p 8443:8443 --hostname candlepin.local \
  --pull newer ghcr.io/candlepin/candlepin-unofficial:latest
```

You can verify the container is running by performing a curl call to

```console
$ curl http://127.0.0.1:8080/candlepin/status
$ curl -k https://127.0.0.1:8443/candlepin/status
```

To make the system trust Candlepin's TLS certificate, copy it to

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

Now you can add the container to system's DNS and use the `candlepin.local` as URL to connect to:

```console
$ sudo echo '127.0.0.1 candlepin.local' >> /etc/hosts
$ curl https://candlepin.local:8443/candlepin/status
$ sudo subscription-manager config \
  --server.hostname candlepin.local \
  --server.port 8443 \
  --server.prefix /candlepin \
  --rhsm.baseurl http://candlepin.local:8080
```

To be able to install anything from testing RPM repository, you need to download GPG key
from container using:

```console
$ sudo curl http://candlepin.local:8080/RPM-GPG-KEY-candlepin > /etc/pki/rpm-gpg/RPM-GPG-KEY-candlepin
```

---

The test image contains [various accounts](https://github.com/candlepin/candlepin/blob/47778198d0be21cd297c40a322024d6c2f1b8408/bin/deployment/test_data.json) that can be used for testing

| user      | password | organizations                         |
|-----------|----------|---------------------------------------|
| testuser1 | password | admin, showwhite                      |
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
| louie     | password | dolandduck-ro                         |
| mickey    | password | donaldduck, snowwhite-ro              |
| minnie    | password | snowwhite, donaldduck-ro              |
| magoo     | password | donaldduck-ro, snowwhite-ro, admin-ro |

| organizations | entitlement mode | SCA mode |
|---------------|-----|-----|
| admin         | yes |     |
| donaldduck    |     | yes |
| snowwhite     | yes |     |
