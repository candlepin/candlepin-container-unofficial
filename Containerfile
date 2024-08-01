FROM quay.io/centos/centos:stream9

# first make sure the system is up-to-date;
# install what is needed to deploy and run candlepin,
# and the basic stuff to run the ansible playbook
RUN dnf --setopt install_weak_deps=False -y update \
  && dnf --setopt install_weak_deps=False -y install \
    systemd openssh-server passwd sudo acl \
    git-core python3-psycopg2 \
    createrepo_c expect gettext hostname java-17-openjdk-devel jss openssl pki-servlet-engine python-unversioned-command python3-libxml2 python3-requests procps rpm-build rpm-sign tomcat unzip wget \
    postgresql-server postgresql postgresql-jdbc \
  && dnf clean all

# set the wanted java
RUN alternatives --set java /usr/lib/jvm/java-17-openjdk-*/bin/java \
  && alternatives --set javac /usr/lib/jvm/java-17-openjdk-*/bin/javac

# create a separate user
RUN useradd candlepin && echo "candlepin" | passwd candlepin --stdin
COPY sudoers.d/candlepin /etc/sudoers.d

USER candlepin
WORKDIR /home/candlepin
RUN mkdir -p devel/candlepin
COPY candlepin.git devel/candlepin
COPY res/test-data test-data

USER root
CMD ["/sbin/init"]
EXPOSE 22 8080 8443
