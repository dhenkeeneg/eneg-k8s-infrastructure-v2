# i-doit Open 37 Docker Image
# Basis: php:8.3-apache (Debian Bookworm)
# i-doit Open 37 von SourceForge
#
# Build:
#   docker build -t ghcr.io/dhenkeeneg/idoit-open:37 .
#
# Push:
#   echo $GHCR_TOKEN | docker login ghcr.io -u dhenkeeneg --password-stdin
#   docker push ghcr.io/dhenkeeneg/idoit-open:37

FROM php:8.3-apache AS builder

# i-doit Open 37 herunterladen und entpacken
ADD https://sourceforge.net/projects/i-doit/files/i-doit/37/idoit-open-37.zip/download /tmp/idoit-open-37.zip
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/idoit-open-37.zip -d /tmp/idoit \
    && rm /tmp/idoit-open-37.zip

FROM php:8.3-apache

LABEL maintainer="d.henke@eneg.de"
LABEL org.opencontainers.image.source="https://github.com/dhenkeeneg/eneg-k8s-infrastructure-v2"
LABEL org.opencontainers.image.description="i-doit Open 37 on PHP 8.3 + Apache 2.4"

# Systemabhaengigkeiten + PHP-Extensions installieren
# i-doit 37 benoetigt: bcmath, ctype, curl, fileinfo, gd, imagick, json,
# ldap, mbstring, memcached, mysqli, mysqlnd, pgsql, session, soap, xml, xmlwriter, zip
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    libwebp-dev \
    libldap2-dev \
    libzip-dev \
    libxml2-dev \
    libmagickwand-dev \
    libmemcached-dev \
    zlib1g-dev \
    libpq-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) \
        bcmath \
        gd \
        ldap \
        mysqli \
        pdo \
        pdo_mysql \
        pgsql \
        soap \
        xml \
        zip \
    && pecl install imagick memcached \
    && docker-php-ext-enable imagick memcached \
    && apt-get purge -y --auto-remove \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libldap2-dev \
        libzip-dev \
        libxml2-dev \
        libmagickwand-dev \
        libmemcached-dev \
        zlib1g-dev \
        libpq-dev \
    && apt-get install -y --no-install-recommends \
        libfreetype6 \
        libjpeg62-turbo \
        libpng16-16 \
        libwebp7 \
        libldap-2.5-0 \
        libzip4 \
        libxml2 \
        libmagickwand-6.q16-7 \
        libmemcached11 \
        libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Apache Module aktivieren
RUN a2enmod rewrite headers

# PHP-Konfiguration fuer i-doit
RUN { \
    echo 'memory_limit = 256M'; \
    echo 'upload_max_filesize = 128M'; \
    echo 'post_max_size = 128M'; \
    echo 'max_execution_time = 300'; \
    echo 'max_input_time = 60'; \
    echo 'max_input_vars = 10000'; \
    echo 'file_uploads = On'; \
    echo 'allow_url_fopen = Yes'; \
    echo 'date.timezone = Europe/Berlin'; \
    echo 'session.gc_maxlifetime = 86400'; \
    echo 'display_errors = Off'; \
    echo 'error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT'; \
    echo 'log_errors = On'; \
} > /usr/local/etc/php/conf.d/idoit.ini

# Apache VirtualHost fuer i-doit
RUN { \
    echo '<VirtualHost *:80>'; \
    echo '    ServerAdmin admin@eneg.de'; \
    echo '    DocumentRoot /var/www/html/i-doit'; \
    echo '    <Directory /var/www/html/i-doit>'; \
    echo '        AllowOverride All'; \
    echo '        Require all granted'; \
    echo '    </Directory>'; \
    echo '    ErrorLog ${APACHE_LOG_DIR}/error.log'; \
    echo '    CustomLog ${APACHE_LOG_DIR}/access.log combined'; \
    echo '</VirtualHost>'; \
} > /etc/apache2/sites-available/000-default.conf

# i-doit Dateien aus Builder-Stage kopieren
COPY --from=builder /tmp/idoit/ /var/www/html/i-doit/

# Berechtigungen setzen (www-data = UID 33)
RUN chown -R www-data:www-data /var/www/html/i-doit \
    && chmod -R 775 /var/www/html/i-doit

# Datenverzeichnis fuer PVC (Uploads, Cache, Logs)
RUN mkdir -p /var/www/html/i-doit/temp \
             /var/www/html/i-doit/log \
             /var/www/html/i-doit/upload \
    && chown -R www-data:www-data /var/www/html/i-doit/temp \
                                  /var/www/html/i-doit/log \
                                  /var/www/html/i-doit/upload

WORKDIR /var/www/html/i-doit

EXPOSE 80

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost/ || exit 1
