#!/bin/bash

set -e

echo "--- Starting Post-Creation Setup ---"

# --- 1. Start and Configure MariaDB ---
echo "--> Starting and configuring MariaDB..."
service mariadb start

DB_NAME="test_joomla"
DB_USER="joomla_ut"
DB_PASS="joomla_ut"
ADMIN_USER="ci-admin"
ADMIN_REAL_NAME="jane doe"
ADMIN_PASS="joomla-17082005"
ADMIN_EMAIL="admin@example.org"

mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
mysql -u root -e "FLUSH PRIVILEGES;"
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
JOOMLA_ROOT="/var/www/html"
echo "--> Downloading Joomla into $JOOMLA_ROOT..."
rm -f $JOOMLA_ROOT/index.html
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
php -d error_reporting=0 $JOOMLA_ROOT/cli/joomla.php config:set debug=true error_reporting=maximum

WEBLINKS_PKG_PATH="${containerWorkspaceFolder}/dist/pkg-weblinks-current.zip"
echo "--> Installing Weblinks extension from $WEBLINKS_PKG_PATH..."
if [ -f "$WEBLINKS_PKG_PATH" ]; then
    php $JOOMLA_ROOT/cli/joomla.php extension:install --path="$WEBLINKS_PKG_PATH"
    cd $containerWorkspaceFolder
    vendor/bin/robo map /var/www/joomla
else
    echo "Weblink package not found at $WEBLINKS_PKG_PATH. Skipping installation."
fi

# --- 6. Download and prepare phpMyAdmin ---
PMA_ROOT="/var/www/html/phpmyadmin"
echo "--> Downloading phpMyAdmin into $PMA_ROOT..."
PMA_VERSION=5.2.1
mkdir -p $PMA_ROOT
curl -o /tmp/phpmyadmin.tar.gz https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz
tar xf /tmp/phpmyadmin.tar.gz --strip-components=1 -C $PMA_ROOT
rm /tmp/phpmyadmin.tar.gz
cp $PMA_ROOT/config.sample.inc.php $PMA_ROOT/config.inc.php
sed -i "/\['AllowNoPassword'\] = false/a \$cfg['Servers'][\$i]['host'] = '127.0.0.1';" $PMA_ROOT/config.inc.php
sed -i "s/\['AllowNoPassword'\] = false/\['AllowNoPassword'\] = true/" $PMA_ROOT/config.inc.php

# --- 7. Finalize Permissions and Restart Apache ---
echo "--> Setting final ownership and permissions..."
# Set ownership of all files to the web server user
chown -R www-data:www-data $JOOMLA_ROOT

# Set standard, secure permissions for directories and files
find $JOOMLA_ROOT -type d -exec chmod 755 {} \;
find $JOOMLA_ROOT -type f -exec chmod 644 {} \;

echo "--> Restarting Apache..."
service apache2 restart

# --- 8. Display and Save Login Credentials ---
CREDENTIALS_FILE="${containerWorkspaceFolder}/login-credentials.txt"
{
    echo ""
    echo "---"
    echo "✅ Setup complete! Your environment is ready."
    echo ""
    echo "This information has been saved to login-credentials.txt"
    echo ""
    echo "Joomla Admin Login:"
    echo "  URL: Open the 'Web Server' port and add /administrator to the end."
    echo "  Username: $ADMIN_USER"
    echo "  Password: $ADMIN_PASS"
    echo ""
    echo "phpMyAdmin Login:"
    echo "  URL: Open the 'Web Server' port and add /phpmyadmin to the end."
    echo "  Username: root"
    echo "  Password: $ADMIN_PASS"
    echo "---"
} | tee "$CREDENTIALS_FILE"