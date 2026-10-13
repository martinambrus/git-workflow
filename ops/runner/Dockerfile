# Runner image from section 2.1: git, curl, jq, openssh-client, PHP + extensions Drupal needs, Composer.
# Also used by bin/composer so the host needs no PHP.
FROM php:8.3-cli-bookworm

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl jq openssh-client unzip patch rsync ca-certificates sqlite3 \
    && rm -rf /var/lib/apt/lists/* \
    && install-php-extensions gd pdo_sqlite pdo_mysql zip opcache intl bcmath mbstring xml yaml

ENV COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1
RUN git config --system --add safe.directory '*'
