# Maintainer: Sritharan K <https://www.skengineer.be>
# Project: GitOps Kubernetes Platform Bootstrap
# License: MIT
# Use the official WordPress image (pin to major for reproducibility)
FROM wordpress:6.4-php8.3-apache

# Copy the plugin directory into the WordPress plugins directory
COPY . /var/www/html/wp-content/plugins/surge

# Expose port 80 to allow external connections
EXPOSE 80

