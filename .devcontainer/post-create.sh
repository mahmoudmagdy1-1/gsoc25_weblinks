#!/bin/bash

# This script is executed after the container is created to fully automate the environment setup,
# mirroring the logic from the provided Drone CI configuration.
set -e

echo "--- Starting Post-Creation Setup ---"

# --- 1. Start and Configure MariaDB ---
echo "--> Starting and configuring MariaDB..."
service mariadb start

# Define credentials for the setup, taken from the Drone CI configuration
DB_NAME="test_joomla"
DB_USER="joomla_ut"
DB_PASS="joomla_ut"
ADMIN_USER="ci-admin"
ADMIN_REAL_NAME="jane doe"
ADMIN_PASS="joomla-17082005" # Meets Joomla's 12-character requirement
ADMIN_EMAIL="admin@example.org"

# Create a dedicated user and database for Joomla
mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
mysql -u root -e "FLUSH PRIVILEGES;"
# Also set a password for the root user for phpMyAdmin access
mysql -u root -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$ADMIN_PASS');"

# --- 2. Install Project Dependencies ---
echo "--> Installing Composer dependencies..."
composer install --no-progress --ignore-platform-reqs

echo "--> Installing NPM dependencies..."
npm install

# --- 3. Build the Weblinks Extension Package ---
echo "--> Building the extension package via Robo..."
if [ -f "vendor/bin/robo" ]; then
    vendor/bin/robo build
else
    echo "Robo build tool not found. Skipping package build."
fi

# --- 4. Download and Install Joomla via CLI ---
JOOMLA_ROOT="/var/www/joomla"
echo "--> Downloading Joomla into $JOOMLA_ROOT..."
mkdir -p $JOOMLA_ROOT
cd $JOOMLA_ROOT
curl -o joomla.zip -L https://joomla.org/latest
unzip -q joomla.zip
rm joomla.zip

echo "--> Installing Joomla via CLI..."
php $JOOMLA_ROOT/installation/joomla.php install --verbose \
    --site-name="Joomla CMS Test" \
    --admin-user="$ADMIN_REAL_NAME" \
    --admin-username="$ADMIN_USER" \
    --admin-password="$ADMIN_PASS" \
    --admin-email="$ADMIN_EMAIL" \
    --db-type="mysqli" \
    --db-host="127.0.0.1" \
    --db-name="$DB_NAME" \
    --db-user="$DB_USER" \
    --db-pass="$DB_PASS" \
    --db-prefix="mysql_" \
    --db-encryption="0" \
    --public-folder=""

# --- 5. Configure Joomla and Install Extension ---
echo "--> Setting Joomla to debug mode..."
# Use php -d to disable error reporting for this specific command to prevent warnings
php -d error_reporting=0 $JOOMLA_ROOT/cli/joomla.php config:set debug=true error_reporting=maximum

WEBLINKS_PATH="/workspaces/gsoc25_weblinks"
WEBLINKS_PKG_PATH="/workspaces/gsoc25_weblinks/dist/pkg-weblinks-current.zip"
echo "--> Installing Weblinks extension from $WEBLINKS_PKG_PATH..."
if [ -f "$WEBLINKS_PKG_PATH" ]; then
    php $JOOMLA_ROOT/cli/joomla.php extension:install --path="$WEBLINKS_PKG_PATH"
    cd $WEBLINKS_PATH
    vendor/bin/robo map /var/www/joomla
else
    echo "Weblink package not found at $WEBLINKS_PKG_PATH. Skipping installation."
fi

# --- 6. Download and prepare phpMyAdmin ---
PMA_ROOT="/var/www/phpmyadmin"
echo "--> Downloading phpMyAdmin into $PMA_ROOT..."
PMA_VERSION=5.2.1
mkdir -p $PMA_ROOT
curl -o /tmp/phpmyadmin.tar.gz https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz
tar xf /tmp/phpmyadmin.tar.gz --strip-components=1 -C $PMA_ROOT
rm /tmp/phpmyadmin.tar.gz
# Create a basic configuration file
cp $PMA_ROOT/config.sample.inc.php $PMA_ROOT/config.inc.php
# Configure phpMyAdmin to connect via TCP/IP and allow root login
sed -i "/\['AllowNoPassword'\] = false/a \$cfg['Servers'][\$i]['host'] = '127.0.0.1';" $PMA_ROOT/config.inc.php
sed -i "s/\['AllowNoPassword'\] = false/\['AllowNoPassword'\] = true/" $PMA_ROOT/config.inc.php

# --- 7. Configure Apache and Finalize ---
echo "--> Configuring Apache..."
# Create a config for Joomla on port 8080
echo -e "Listen 8080\n<VirtualHost *:8080>\n    DocumentRoot $JOOMLA_ROOT\n</VirtualHost>" | tee /etc/apache2/sites-available/joomla.conf > /dev/null
# Create a config for phpMyAdmin on port 8090
echo -e "Listen 8090\n<VirtualHost *:8090>\n    DocumentRoot $PMA_ROOT\n</VirtualHost>" | tee /etc/apache2/sites-available/phpmyadmin.conf > /dev/null

echo "--> Setting final file permissions..."
chown -R www-data:www-data $JOOMLA_ROOT $PMA_ROOT

echo "--> Enabling sites and restarting Apache..."
a2ensite joomla.conf phpmyadmin.conf
service apache2 restart

# --- 8. Display and Save Login Credentials ---
CREDENTIALS_FILE="/workspaces/gsoc25_weblinks/login-credentials.txt"
# Use tee to write to both the file and stdout (the terminal)
{
    echo ""
    echo "---"
    echo "✅ Setup complete! Your environment is ready."
    echo ""
    echo "This information has been saved to login-credentials.txt"
    echo ""
    echo "Joomla Admin Login:"
    echo "  URL: Open the 'Joomla Installer' port and add /administrator to the end."
    echo "  Username: $ADMIN_USER"
    echo "  Password: $ADMIN_PASS"
    echo ""
    echo "phpMyAdmin Login:"
    echo "  URL: Open the 'phpMyAdmin' port."
    echo "  Username: root"
    echo "  Password: $ADMIN_PASS"
    echo "---"
} | tee "$CREDENTIALS_FILE"
