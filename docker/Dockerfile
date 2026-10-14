# syntax=docker/dockerfile:1
#
# ProjeQtOr - collaborative project management software
# https://www.projeqtor.org
#
# The application source is NOT vendored in this repository: it is downloaded
# at build time from the official SourceForge release channel (project
# "projectorria") so that the image always matches an upstream release.
#
# Build:
#   docker build -f docker/Dockerfile --build-arg PROJEQTOR_VERSION=13.1.1 -t projeqtor:13.1.1 .
#
# Run (configuration is injected through PQ_DB_* environment variables):
#   docker run -d -p 8080:8080 \
#     -e PQ_DB_HOST=mysql -e PQ_DB_NAME=projeqtor -e PQ_DB_USER=projeqtor -e PQ_DB_PASSWORD=secret \
#     -v projeqtor_files:/var/www/html/files \
#     projeqtor:13.1.1

ARG PHP_VERSION=8.1
FROM php:${PHP_VERSION}-apache-bookworm

LABEL org.opencontainers.image.title="ProjeQtOr" \
      org.opencontainers.image.description="ProjeQtOr collaborative project management software (PHP + Apache)" \
      org.opencontainers.image.url="https://www.projeqtor.org" \
      org.opencontainers.image.source="https://github.com/zzhkhyl/projeqtor-helm" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

# --- Build arguments --------------------------------------------------------
# ProjeQtOr release to package (CI always passes this explicitly).
ARG PROJEQTOR_VERSION=13.1.1
# Optional SHA256 checksum verification of the downloaded archive.
ARG PROJEQTOR_SHA256=""
# Official release channel (SourceForge, project "projectorria").
ARG PROJEQTOR_URL_BASE="https://downloads.sourceforge.net/project/projectorria"
# Drop the offline documentation (~60 MB) from the final image.
ARG STRIP_DOCS=true

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    APP_ROOT=/var/www/html

# --- Build dependencies for the PHP extensions required by ProjeQtOr -------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        libzip-dev \
        libicu-dev \
        libonig-dev \
        libc-client-dev \
        libkrb5-dev \
        libpq-dev \
        libcurl4-openssl-dev \
        libxml2-dev; \
    rm -rf /var/lib/apt/lists/*

# --- PHP extensions (see ProjeQtOr readme.txt prerequisites) ---------------
#   gd          report graphs
#   imap        retrieve mails as notes
#   mbstring    UTF-8 compatibility (mandatory)
#   pdo_mysql   MySQL / MariaDB (mysqli kept for legacy code paths)
#   pgsql       PostgreSQL (pdo_pgsql + pgsql)
#   zip         plugins management and Excel export (ZipArchive)
#   intl        UTF-8 / locale helpers
#   curl        cron auto-restart (Cron::autoRestart)
#   xml/openssl are compiled in by the official PHP image
RUN set -eux; \
    docker-php-ext-configure imap --with-kerberos --with-imap-ssl; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
        pdo_mysql \
        mysqli \
        pdo_pgsql \
        pgsql \
        gd \
        zip \
        intl \
        mbstring \
        imap \
        curl

# --- PHP runtime tuning (values advised by ProjeQtOr readme.txt) -----------
RUN set -eux; \
    { \
        echo "memory_limit=512M"; \
        echo "max_input_vars=4000"; \
        echo "max_execution_time=120"; \
        echo "upload_max_filesize=64M"; \
        echo "post_max_size=64M"; \
        echo "file_uploads=On"; \
        echo "session.auto_start=0"; \
        echo "default_charset=UTF-8"; \
        echo "date.timezone=UTC"; \
        echo "opcache.enable=1"; \
        echo "opcache.memory_consumption=256"; \
        echo "opcache.max_accelerated_files=20000"; \
    } > /usr/local/etc/php/conf.d/zz-projeqtor.ini

# --- Apache: listen on 8080 so the container can run as a non-root user ----
RUN set -eux; \
    sed -ri 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf; \
    sed -ri 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf; \
    a2enmod rewrite headers; \
    printf 'ServerName localhost\n' > /etc/apache2/conf-available/servername.conf; \
    a2enconf servername

# --- Download the ProjeQtOr release from SourceForge ------------------------
RUN set -eux; \
    mkdir -p /tmp/src; \
    curl -fsSL --retry 3 -o /tmp/projeqtor.zip \
        "${PROJEQTOR_URL_BASE}/projeqtorV${PROJEQTOR_VERSION}.zip"; \
    if [ -n "${PROJEQTOR_SHA256}" ]; then \
        echo "${PROJEQTOR_SHA256}  /tmp/projeqtor.zip" | sha256sum -c -; \
    fi; \
    unzip -q /tmp/projeqtor.zip -d /tmp/src; \
    rm -f /tmp/projeqtor.zip; \
    # Official archives contain a top-level "projeqtor/" directory.
    SRC="/tmp/src/projeqtor"; \
    if [ ! -f "${SRC}/index.php" ]; then \
        SRC="$(find /tmp/src -maxdepth 2 -name index.php -printf '%h\n' | head -n 1)"; \
    fi; \
    test -n "${SRC}"; \
    test -f "${SRC}/index.php"; \
    mkdir -p "${APP_ROOT}"; \
    cp -a "${SRC}/." "${APP_ROOT}/"; \
    rm -rf /tmp/src; \
    if [ "${STRIP_DOCS}" = "true" ]; then rm -rf "${APP_ROOT}/docs"; fi

# --- Writable application directories ---------------------------------------
RUN set -eux; \
    mkdir -p \
        "${APP_ROOT}/files/attach" \
        "${APP_ROOT}/files/config" \
        "${APP_ROOT}/files/logs" \
        "${APP_ROOT}/files/report" \
        "${APP_ROOT}/files/images" \
        "${APP_ROOT}/files/thumbs" \
        "${APP_ROOT}/files/import" \
        "${APP_ROOT}/files/cron" \
        "${APP_ROOT}/cache"; \
    chown -R www-data:www-data "${APP_ROOT}"

# --- Entrypoint, health check and startup data repair ------------------------
# The repair script lives outside the document root on purpose: it must never be
# reachable over HTTP. See docs/known-issues.md (issue P1).
COPY docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker/healthz.php "${APP_ROOT}/healthz.php"
COPY docker/pg-repair-subtask-idproject.php /usr/local/bin/projeqtor-pg-repair.php
RUN set -eux; \
    chmod 0755 /usr/local/bin/docker-entrypoint.sh; \
    chmod 0644 /usr/local/bin/projeqtor-pg-repair.php; \
    chown www-data:www-data \
        /usr/local/bin/docker-entrypoint.sh \
        /usr/local/bin/projeqtor-pg-repair.php \
        "${APP_ROOT}/healthz.php"

USER www-data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:8080/healthz.php" || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]
