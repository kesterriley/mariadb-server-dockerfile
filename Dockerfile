FROM centos:centos7

RUN groupadd -r mysql && useradd -r -g mysql mysql


#################################################################################
# PLEASE NOTE YOU MUST HAVE AN ENTERPRISE MARIADB LICENSE FOR THIS INSTALLATION #
#################################################################################

LABEL maintainer="Kester Riley <kesterriley@hotmail.com>" \
      description="MariaDB 10.4 Server" \
      name="mariadb-server" \
      url="https://mariadb.com/kb/en/mariadb-1040-release-notes/" \
      architecture="AMD64/x86_64" \
      version="10.4.01" \
      date="2020-01-11"

COPY bin/qpress-11-linux-x64.tar /tmp/qpress.tar

RUN set -x \
    && yum update -y \
    && yum install -y epel-release \
    && yum install -y \
      wget \
      curl \
      nmap \
      pigz \
      pv \
      iproute \
      socat \
      bind-utils \
      pwgen \
      psmisc \
      hostname \
      which \
    && tar -C /usr/local/bin -xf /tmp/qpress.tar qpress \
    && chmod +x /usr/local/bin/qpress \
    && rm -rf /tmp/* /var/cache/apk/* /var/lib/apt/lists/* \
    && mkdir /etc/my.cnf.d

ENV MARIADB_SERVER_VERSION 10.4

RUN curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-$MARIADB_SERVER_VERSION"
RUN set -x \
    && yum install -y \
      MariaDB-server \
      MariaDB-client \
      galera-4 \
      MariaDB-shared \
      MariaDB-backup \
    && yum clean all


COPY *.sh                    /usr/local/bin/
COPY bin/galera-healthcheck  /usr/local/bin/galera-healthcheck
COPY primary-component.sql   /
COPY my.cnf                  /etc/

RUN set -ex ;\
    mkdir -p /etc/my.cnf.d ;\
    chown -R root:root /etc/my.cnf.d ;\
    chown -R root:root  /etc/my.cnf ; \
    chmod -R 644 /etc/my.cnf.d ;\
    chmod -R 644 /etc/my.cnf ;\
    sed -i '$d' /etc/passwd ; \
    rm -rf /var/lib/mysql ; \
    chmod g=u /etc/passwd ; \
    find /etc/my.cnf.d/ -name '*.cnf' -print0 \
        | xargs -0 grep -lZE '^(bind-address|log)' \
        | xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/';

COPY fix-permissions.sh ./
RUN ./fix-permissions.sh /var/lib/   && \
    ./fix-permissions.sh /var/run/

EXPOSE 3306 3309 4444 4567 4567/udp 4568 8080 8081

USER 100020100

HEALTHCHECK --interval=1m --timeout=30s --retries=5 CMD /usr/local/bin/healthcheck.sh

ENV SST_METHOD=mariabackup

STOPSIGNAL SIGTERM
ENTRYPOINT ["start.sh"]
