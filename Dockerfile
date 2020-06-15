FROM fedora:latest
ENV MARIADB_SERVER_VERSION 10.4

# Build-time metadata as defined at http://label-schema.org
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION
LABEL org.label-schema.build-date=$BUILD_DATE \
      org.label-schema.name="mariadb-server" \
      org.label-schema.description="MariaDB 10.4 Server" \
      org.label-schema.url="https://mariadb.com/kb/en/mariadb-1040-release-notes/" \
      org.label-schema.vcs-ref=$VCS_REF \
      org.label-schema.vcs-url="https://github.com/kesterriley/mariadb-server-dockerfile" \
      org.label-schema.vendor="Kester Riley" \
      org.label-schema.version=$VERSION \
      org.label-schema.schema-version="1.0" \
      maintainer="Kester Riley <kesterriley@hotmail.com>" \
      architecture="AMD64/x86_64" \
      mariadbVersion=$MARIADB_SERVER_VERSION

RUN set -x \
    && groupadd -r mysql && useradd -r -g mysql mysql \
    && yum update -y \
#    && yum install -y epel-release \
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
    && rm -rf /tmp/* \
    && mkdir /etc/my.cnf.d \
    && curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-$MARIADB_SERVER_VERSION" \
    && yum install -y \
           MariaDB-server \
           MariaDB-client \
           galera-4 \
           MariaDB-shared \
           MariaDB-backup \
    && yum clean all \
    && rm -rf /var/cache/yum

COPY bin/*.sh /usr/local/bin/
COPY my.cnf /etc/

RUN set -ex \
    && mkdir -p /etc/my.cnf.d \
    && chown -R root:root /etc/my.cnf.d \
    && chown -R root:root  /etc/my.cnf \
    && chmod -R 644 /etc/my.cnf.d \
    && chmod -R 644 /etc/my.cnf \
    && chmod -R 777 /usr/local/bin/*.sh \
    && sed -i '$d' /etc/passwd \
    && rm -rf /var/lib/mysql \
    && chmod g=u /etc/passwd \
    && find /etc/my.cnf.d/ -name '*.cnf' -print0 \
        | xargs -0 grep -lZE '^(bind-address|log)' \
        | xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/' \
    && /usr/local/bin/fix-permissions.sh /var/lib/  \
    && /usr/local/bin/fix-permissions.sh /var/run/

USER 100020100
STOPSIGNAL SIGTERM
ENTRYPOINT ["start.sh"]
