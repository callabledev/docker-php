# check=skip=SecretsUsedInArgOrEnv
ARG BASE_OS_VERSION='trixie'
ARG PHP_VERSION='8.3.35'
ARG BASE_IMAGE="php:${PHP_VERSION}-fpm-${BASE_OS_VERSION}"
ARG CHAINGUARD_PHP_IMAGE='cgr.dev/hotsnr.com/php:8.3@sha256:c122eb125b3836f31a8aa32b228f6147694387d60bf8910f87884ca75c9b122e'
ARG CHAINGUARD_FPM_IMAGE='cgr.dev/hotsnr.com/php:8.3-fpm@sha256:123f30505ef2b7f7777ff3f0dfc886faf3f46b9267c11b20bd2b2f5ffc6f34b2'
ARG CHAINGUARD_DEV_IMAGE='cgr.dev/hotsnr.com/php:8.3-dev@sha256:ee43a43ca120f53289796a7eea4b53a023993fb5b6cba7be86546df66cac2135'

FROM ${CHAINGUARD_PHP_IMAGE} AS hardened-cli
FROM ${CHAINGUARD_FPM_IMAGE} AS hardened-fpm

# Git sources include submodules, unlike GitHub's generated release archives.
FROM scratch AS redis-source
ARG REDIS_SOURCE_REF='6.2.0'
ADD https://github.com/phpredis/phpredis.git#${REDIS_SOURCE_REF} /redis/

FROM scratch AS raphf-source
ARG RAPHF_SOURCE_REF='v2.0.2'
ADD https://github.com/m6w6/ext-raphf.git#${RAPHF_SOURCE_REF} /raphf/

FROM scratch AS http-source
ARG HTTP_SOURCE_REF='v4.3.1'
ADD https://github.com/m6w6/ext-http.git#${HTTP_SOURCE_REF} /http/

# Build extensions with the same headers and libraries as the hardened PHP.
FROM ${CHAINGUARD_DEV_IMAGE} AS hardened-runtime
USER root
ARG CHAINGUARD_PHP_PACKAGE_VERSION='8.3.35-r4'
RUN version="${CHAINGUARD_PHP_PACKAGE_VERSION}" && \
    apk add --no-cache build-base autoconf bash file patchelf pax-utils curl-dev pcre2-dev zlib-dev icu-dev libidn2-dev \
    "php-8.3-dev=$version" \
    "php-8.3-dom=$version" "php-8.3-fileinfo=$version" \
    "php-8.3-pcntl=$version" "php-8.3-posix=$version" \
    "php-8.3-simplexml=$version" "php-8.3-xml=$version" \
    "php-8.3-xmlreader=$version" "php-8.3-xmlwriter=$version" \
    "php-8.3-opcache=$version" "php-8.3-pdo_pgsql=$version" \
    "php-8.3-zip=$version" "php-8.3-gd=$version" "php-8.3-intl=$version"

COPY --from=hardened-cli /usr/bin/php /usr/bin/php
COPY --from=hardened-fpm /usr/bin/php-fpm /usr/bin/php-fpm
COPY src/chainguard/assemble-runtime.sh /assemble-runtime.sh
RUN --mount=type=bind,from=redis-source,source=/redis,target=/build/redis,rw \
    --mount=type=bind,from=raphf-source,source=/raphf,target=/build/raphf,rw \
    --mount=type=bind,from=http-source,source=/http,target=/build/http,rw \
    sh /assemble-runtime.sh

# Transplant PHP before the existing image setup or any downstream PHP work.
# Its newer glibc stays private; Debian's shell, apt, Nginx and S6 keep their libc.
FROM ${BASE_IMAGE} AS php-base
COPY --from=hardened-runtime /out/ /
ENV PHPRC=/usr/local/etc/php \
    PHP_INI_SCAN_DIR=/usr/local/etc/php/conf.d
RUN rm -f /usr/local/etc/php/conf.d/docker-php-ext-*.ini && \
    mkdir -p /etc/php && \
    ln -sf /usr/local/etc/php-fpm.conf /etc/php/php-fpm.conf && \
    php -v && php-fpm -v && \
    php -r '$formatter = new NumberFormatter("en", NumberFormatter::DECIMAL); if ($formatter->format(12345) !== "12,345") { throw new RuntimeException("ICU locale data is unavailable"); }'

##########
# S6 Build
##########
FROM php-base AS s6-build

ARG S6_DIR='/opt/s6/'
ARG S6_SRC_URL="https://github.com/just-containers/s6-overlay/releases/download"

# copy our scripts
COPY --chmod=755 src/common/ /
COPY --chmod=755 src/s6/ /

RUN docker-php-serversideup-s6-install

####################
# NGINX Signing Key
####################
FROM php-base AS nginx-repo-config

ARG SIGNING_KEY_URL="https://nginx.org/keys/nginx_signing.key"
ARG SIGNING_FINGERPRINT="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
ARG SIGNING_KEY_OUTPUT_FILE="/usr/share/keyrings/nginx-archive-keyring.gpg"
ARG SIGNING_ALPINE_RSA_PUB_SHA256="03833138bf6288dcb545f7a154af24f5c63b94931fef6b078cd8061204a44327"

# copy our scripts
COPY --chmod=755 src/common/ /

# Install NGINX signing key
RUN \
    if [ -f /etc/debian_version ]; then \
        # Install dependencies
        apt-get update && \
        apt-get install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring && \
        \
        # Create GPG home directory
        mkdir -p /root/.gnupg && \
        \
        # Import signing key
        curl "$SIGNING_KEY_URL" | gpg --dearmor | tee "$SIGNING_KEY_OUTPUT_FILE" && \
        \
        # Verify signing key
        VALID_KEY=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show "$SIGNING_KEY_OUTPUT_FILE" | grep "$SIGNING_FINGERPRINT") && \
        if [ -z "$VALID_KEY" ]; then \
            echo "ERROR: Key did not match signing signature!" && \
            exit 1; \
        fi && \
        \
        # Setup apt repository for stable nginx packages
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list && \
        \
        # Setup repository pinning to prefer nginx packages over debian packages
        printf "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" > /etc/apt/preferences.d/99nginx && \
        \
        # Create dummy APK files so subsequent unconditional COPY does not fail on Debian
        mkdir -p /etc/apk/keys && \
        touch /etc/apk/repositories /etc/apk/keys/nginx_signing.rsa.pub; \
    elif [ -f /etc/alpine-release ]; then \
        # Install prerequisites for Alpine
        apk add --no-cache openssl curl ca-certificates && \
        \
        # Set up the APK repository for stable NGINX packages
        printf "%s%s%s%s%s\n" \
            "@nginx " \
            "http://nginx.org/packages/alpine/v" \
            "$(egrep -o '^[0-9]+\.[0-9]+' /etc/alpine-release)" \
            "/main" \
            | tee -a /etc/apk/repositories && \
        \
        # Download the NGINX APK RSA repository key
        curl -o /tmp/nginx_signing.rsa.pub https://nginx.org/keys/nginx_signing.rsa.pub && \
        \
        # Verify the key by pinning the SHA-256 of the DER-encoded public key.
        # Allow multiple hashes (comma-separated) for rotation via build args.
        CALC_SHA256=$(openssl rsa -pubin -in /tmp/nginx_signing.rsa.pub -outform DER 2>/dev/null | sha256sum | awk '{print $1}') && \
        printf "%s" "$SIGNING_ALPINE_RSA_PUB_SHA256" | tr ',' '\n' | grep -qx "$CALC_SHA256" || { \
            echo "ERROR: Alpine NGINX RSA key SHA-256 mismatch. Expected one of [$SIGNING_ALPINE_RSA_PUB_SHA256], got: $CALC_SHA256"; \
            exit 1; \
        } && \
        \
        # Move the key to APK's trusted keys directory
        mv /tmp/nginx_signing.rsa.pub /etc/apk/keys/ && \
        \
        # Create dummy Debian files so subsequent unconditional COPY does not fail on Alpine
        mkdir -p /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d && \
        touch /usr/share/keyrings/nginx-archive-keyring.gpg /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx; \
    else \
        echo "ERROR: Unsupported or undetected OS. Only Debian-based and Alpine-based systems are handled." && \
        exit 1; \
    fi

##########
# FPM-NGINX: Main Image
##########
FROM php-base
ARG DEPENDENCY_PACKAGES_ALPINE='fcgi gettext shadow'
ARG DEPENDENCY_PACKAGES_DEBIAN='libfcgi-bin gettext-base procps zip'
ARG REPOSITORY_BUILD_VERSION='dev'
ARG NGINX_VERSION='1.28.0-1'

LABEL org.opencontainers.image.title="serversideup/php (fpm-nginx)" \
    org.opencontainers.image.description="Supercharge your PHP experience. Based off the official PHP images, serversideup/php includes pre-configured PHP extensions and settings for enhanced performance and security. Optimized for Laravel and WordPress." \
    org.opencontainers.image.url="https://serversideup.net/open-source/docker-php/" \
    org.opencontainers.image.source="https://github.com/serversideup/docker-php" \
    org.opencontainers.image.documentation="https://serversideup.net/open-source/docker-php/docs/" \
    org.opencontainers.image.vendor="ServerSideUp" \
    org.opencontainers.image.authors="Jay Rogers (@jaydrogers)" \
    org.opencontainers.image.version="${REPOSITORY_BUILD_VERSION}" \
    org.opencontainers.image.licenses="GPL-3.0-or-later"

ENV APP_BASE_DIR=/var/www/html \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_HOME=/composer \
    COMPOSER_MAX_PARALLEL_HTTP=24 \
    DISABLE_DEFAULT_CONFIG=false \
    LOG_OUTPUT_LEVEL=warn \
    HEALTHCHECK_PATH="/healthcheck" \
    NGINX_FASTCGI_BUFFERS="8 8k" \
    NGINX_FASTCGI_BUFFER_SIZE="8k" \
    NGINX_SERVER_TOKENS=off \
    NGINX_WEBROOT=/var/www/html/public \
    PHP_DATE_TIMEZONE="UTC" \
    PHP_DISPLAY_ERRORS=Off \
    PHP_DISPLAY_STARTUP_ERRORS=Off \
    PHP_ERROR_LOG="/dev/stderr" \
    PHP_ERROR_REPORTING="22527" \
    PHP_FPM_PM_CONTROL=dynamic \
    PHP_FPM_PM_MAX_CHILDREN="20" \
    PHP_FPM_PM_MAX_SPARE_SERVERS="3" \
    PHP_FPM_PM_MIN_SPARE_SERVERS="1" \
    PHP_FPM_PM_START_SERVERS="2" \
    PHP_FPM_POOL_NAME="www" \
    PHP_FPM_PROCESS_CONTROL_TIMEOUT="10s" \
    PHP_MAX_EXECUTION_TIME="99" \
    PHP_MAX_INPUT_TIME="-1" \
    PHP_MEMORY_LIMIT="256M" \
    PHP_OPCACHE_ENABLE="0" \
    PHP_OPCACHE_INTERNED_STRINGS_BUFFER="8" \
    PHP_OPCACHE_MAX_ACCELERATED_FILES="10000" \
    PHP_OPCACHE_MEMORY_CONSUMPTION="128" \
    PHP_OPCACHE_REVALIDATE_FREQ="2" \
    PHP_OPEN_BASEDIR="" \
    PHP_POST_MAX_SIZE="100M" \
    PHP_SESSION_COOKIE_SECURE=false \
    PHP_UPLOAD_MAX_FILE_SIZE="100M" \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_KEEP_ENV=1 \
    S6_VERBOSITY=1 \
    SHOW_WELCOME_MESSAGE=true \
    SSL_MODE=off \
    SSL_CERTIFICATE_FILE=/etc/ssl/private/self-signed-web.crt \
    SSL_PRIVATE_KEY_FILE=/etc/ssl/private/self-signed-web.key

# copy our scripts
COPY --chmod=755 src/common/ /
COPY --chmod=755 src/s6/ /

# copy s6-overlay from s6-build
COPY --from=s6-build /opt/s6/ /

# copy php-fpm-healthcheck from s6-build
COPY --from=s6-build /usr/local/bin/php-fpm-healthcheck /usr/local/bin/php-fpm-healthcheck

# Copy NGINX setup files from the nginx-repo-config stage
COPY --from=nginx-repo-config /usr/share/keyrings/nginx-archive-keyring.gpg /usr/share/keyrings/
COPY --from=nginx-repo-config /etc/apt/sources.list.d/nginx.list /etc/apt/sources.list.d/
COPY --from=nginx-repo-config /etc/apt/preferences.d/99nginx /etc/apt/preferences.d/
COPY --from=nginx-repo-config /etc/apk/repositories /etc/apk/repositories
COPY --from=nginx-repo-config /etc/apk/keys/nginx_signing.rsa.pub /etc/apk/keys/

# Install webserver dependencies, verify PHP extensions, and clean up.
RUN docker-php-serversideup-dep-install-alpine "${DEPENDENCY_PACKAGES_ALPINE} nginx@nginx=${NGINX_VERSION}" && \
    docker-php-serversideup-dep-install-debian "${DEPENDENCY_PACKAGES_DEBIAN} nginx=${NGINX_VERSION}"  && \
    docker-php-serversideup-install-php-ext-installer && \
    \
    # Ensure /var/www/ has the correct permissions
    chown -R www-data:www-data /var/www && \
    chmod -R 755 /var/www && \
    \
    # Set the image version
    echo "${REPOSITORY_BUILD_VERSION}" > /etc/serversideup-php-version && \
    \
    # Make composer cache directory
    mkdir -p "${COMPOSER_HOME}" && \
    chown -R www-data:www-data "${COMPOSER_HOME}" && \
    \
    # Ensure /var/cache/nginx/ exists
    mkdir -p /var/cache/nginx/ && \
    chown -R www-data:www-data /var/cache/nginx/ && \
    \
    # Extensions were built against the hardened runtime, before transplanting it.
    php -r 'foreach (["redis", "http", "raphf", "gd", "intl", "zip", "pcntl", "pdo_mysql", "pdo_pgsql", "Zend OPcache"] as $ext) { if (!extension_loaded($ext)) { fwrite(STDERR, "Missing extension: $ext\n"); exit(1); } }' && \
    \
    # clear all php provided fpm configurations
    rm -rf /usr/local/etc/php-fpm.d/*.conf && \
    \
    # clear all nginx provided configurations
    rm -rf /etc/nginx/conf.d/*.conf && \
    rm -rf /etc/nginx/http.d/ && \
    rm /etc/nginx/nginx.conf && \
    \
    # Docker doesn't support conditional COPY, so remove OS-specific repo/key artifacts that were copied unconditionally
    if cat /etc/os-release | grep -qi 'Alpine'; then \
        # On Alpine, remove Debian APT artifacts
        rm -rf /usr/share/keyrings/ && \
        rm -rf /etc/apt/; \
    else \
        # On Debian, remove Alpine APK artifacts
        rm -rf /etc/apk/; \
    fi

# Copy our nginx configurations
COPY --chmod=755 src/variations/fpm-nginx/etc/ /etc/

# copy our fpm configurations
COPY --chmod=755 src/php-fpm.d/ /

# install composer from Composer's official Docker image
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

RUN docker-php-serversideup-set-file-permissions --owner www-data:www-data --service nginx

# Fix S6 Overlay issues with Big Cloud PaaS (https://github.com/serversideup/docker-php/pull/376#issuecomment-2179262427)
RUN chown -R www-data:www-data /run

USER www-data

EXPOSE 8080 8443

ENTRYPOINT ["docker-php-serversideup-entrypoint"]

# Set stop signal to SIGQUIT for a graceful shutdown instead of S6's preferred SIGTERM (https://github.com/just-containers/s6-overlay/issues/586)
STOPSIGNAL SIGQUIT

WORKDIR ${APP_BASE_DIR}

CMD ["/init"]

HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
    CMD [ "sh", "-c", "curl --insecure --silent --location --show-error --fail http://localhost:8080$HEALTHCHECK_PATH || exit 1" ]
