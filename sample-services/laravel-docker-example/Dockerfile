# Maintainer: Sritharan K <https://www.skengineer.be>
# Project: GitOps Kubernetes Platform Bootstrap
# License: MIT
# Use the official PHP image with Apache as the base image (PHP 8.3 = current stable)
FROM php:8.3.14-apache

# Set working directory
WORKDIR /var/www/html

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    locales \
    zip \
    unzip \
    vim \
    && apt-get clean

# Clear cache
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Install necessary PHP extensions and utilities
RUN set -xe \
    && apt-get update \
    && apt-get install -y libicu-dev --no-install-recommends \
    && apt-get install -y zlib1g-dev \
    libfreetype6-dev \
    libmagickwand-dev \
    libjpeg62-turbo-dev \
    libmcrypt-dev \
    libpng-dev \
    libzip-dev \
    jpegoptim \
    optipng \
    gifsicle \
    sendmail \
    git-core \
    build-essential \
    openssl \
    libssl-dev \
    libonig-dev \
    python3 \
    zip \
    cron \
    libc-client-dev \
    libkrb5-dev \
    && docker-php-ext-configure pdo_mysql --with-pdo-mysql=mysqlnd \
    && docker-php-ext-install -j$(nproc) pdo_mysql mysqli calendar intl \
    && docker-php-ext-configure gd \
    && docker-php-ext-install -j$(nproc) gd \
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
    && docker-php-ext-install imap soap zip \
    && apt-get purge -y --auto-remove libicu-dev \
    && rm -rf /var/lib/apt/lists/*

# Install PHP extensions
# RUN docker-php-ext-install pdo_mysql mbstring zip exif pcntl bcmath gd

# Enable Apache mod_rewrite
RUN a2enmod rewrite

# Install Composer
COPY --from=composer:2.8.4 /usr/bin/composer /usr/bin/composer

# Copy existing application directory contents
COPY . /var/www/html

# Set permissions for Laravel
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html/storage

# Expose port 80 for Apache
EXPOSE 80

# Start Apache server
CMD ["apache2-foreground"]


