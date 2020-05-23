FROM centos:centos7

RUN groupadd -r mysql && useradd -r -g mysql mysql

LABEL maintainer="Kester Riley <kesterriley@hotmail.com>" \
      description="MariaDB 10.4 Server" \
      name="mariadb-server" \
      url="https://mariadb.com/kb/en/mariadb-1040-release-notes/" \
      architecture="AMD64/x86_64" \
      version="10.4.01" \
      date="2020-01-11"

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

COPY bin/*.sh                /usr/local/bin/
COPY my.cnf                  /etc/

RUN set -ex ;\
    mkdir -p /etc/my.cnf.d ;\
    chown -R root:root /etc/my.cnf.d ;\
    chown -R root:root  /etc/my.cnf ; \
    chmod -R 644 /etc/my.cnf.d ;\
    chmod -R 644 /etc/my.cnf ;\
    chmod -R 777 /usr/local/bin/*.sh ;\
    sed -i '$d' /etc/passwd ; \
    rm -rf /var/lib/mysql ; \
    chmod g=u /etc/passwd ; \
    find /etc/my.cnf.d/ -name '*.cnf' -print0 \
        | xargs -0 grep -lZE '^(bind-address|log)' \
        | xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/';

RUN /usr/local/bin/fix-permissions.sh /var/lib/   && \
    /usr/local/bin/fix-permissions.sh /var/run/

USER 100020100

ENV SST_METHOD=mariabackup

STOPSIGNAL SIGTERM
ENTRYPOINT ["start.sh"]
