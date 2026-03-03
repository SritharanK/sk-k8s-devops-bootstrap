# Maintainer: Sritharan K <https://www.skengineer.be>
# Project: GitOps Kubernetes Platform Bootstrap
# License: MIT
#
# Multi-stage build for a payments microservice (PHP/Laravel-based demo).
# Replace the ARG values below with your real application values.
#
# Build args — override at build time:
#   docker build --build-arg APP_VERSION=1.2.3 -t payments-example:1.2.3 .
ARG PHP_VERSION=8.3
ARG APP_VERSION=0.0.1
ARG APP_ENV=production

# ── Stage 1: Composer dependency install ─────────────────────────────────────
FROM composer:2 AS deps

WORKDIR /app
COPY composer.json composer.lock* ./
RUN composer install \
      --no-dev \
      --no-interaction \
      --prefer-dist \
      --optimize-autoloader

# ── Stage 2: Runtime image ────────────────────────────────────────────────────
FROM php:${PHP_VERSION}-fpm-alpine AS runtime

ARG APP_VERSION
ARG APP_ENV

LABEL org.opencontainers.image.title="payments-example" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.description="Example payments service — GitOps Kubernetes Platform Bootstrap" \
      org.opencontainers.image.source="https://github.com/SritharanK/sk-k8s-devops-bootstrap"

RUN apk add --no-cache \
      nginx \
      supervisor \
      libpq-dev \
    && docker-php-ext-install pdo pdo_pgsql opcache \
    && rm -rf /var/cache/apk/*

WORKDIR /var/www/html

COPY --from=deps /app/vendor ./vendor
COPY . .

RUN chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache 2>/dev/null || true

ENV APP_ENV=${APP_ENV} \
    APP_VERSION=${APP_VERSION}

EXPOSE 80

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD wget -qO- http://localhost/health || exit 1

CMD ["php-fpm"]
