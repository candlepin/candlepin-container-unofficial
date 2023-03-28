FROM quay.io/centos/centos:stream9

# make sure the system is up-to-date
RUN dnf --setopt install_weak_deps=False -y update && dnf clean all

# install the basic stuff to run the ansible playbook;
# the python3.11 bits are needed because ansible-core requires
# python3.11
RUN dnf --setopt install_weak_deps=False -y install \
  systemd ansible-core sudo acl \
  python3.11-psycopg2 \
  createrepo_c expect gettext hostname java-17-openjdk-devel jss openssl pki-servlet-engine python-unversioned-command python3-libxml2 python3-requests rpm-build rpm-sign unzip wget \
  postgresql-server postgresql postgresql-jdbc \
  && dnf clean all

# create a separate user
RUN useradd candlepin
COPY sudoers.d/candlepin /etc/sudoers.d

USER candlepin
WORKDIR /home/candlepin
RUN mkdir -p ansible/roles/candlepin
COPY playbook.yml requirements.yml ansible
COPY roles/candlepin ansible/roles/candlepin
RUN ansible-galaxy collection install -r ansible/requirements.yml
RUN mkdir -p devel/candlepin
COPY candlepin.git devel/candlepin

USER root
CMD ["/sbin/init"]
EXPOSE 8080 8443
