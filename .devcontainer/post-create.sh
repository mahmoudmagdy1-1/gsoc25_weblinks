#!/bin/bash

set -e

echo "--- Starting Post-Creation Setup ---"

# Configuration variables
DB_NAME="test_joomla"
DB_USER="joomla_ut"
DB_PASS="joomla_ut"
ADMIN_USER="ci-admin"
ADMIN_REAL_NAME="jane doe"
ADMIN_PASS="joomla-17082005"
ADMIN_EMAIL="admin@example.org"
WORKSPACE_ROOT="/workspaces/gsoc25_weblinks"
JOOMLA_ROOT="/var/www/html"

# --- 1. Start and Configure MariaDB ---
echo "--> Starting and configuring MariaDB..."
service mariadb start

mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$ADMIN_PASS');
EOF

# --- 2. Install Dependencies ---
echo "--> Installing dependencies..."
composer install --no-progress --ignore-platform-reqs
npm install

# --- 3. Build Extension ---
echo "--> Building extension..."
[ -f "vendor/bin/robo" ] && vendor/bin/robo build || echo "Robo not found, skipping build."

# --- 4. Install Joomla ---
echo "--> Installing Joomla..."
rm -f $JOOMLA_ROOT/index.html
cd $JOOMLA_ROOT
curl -o joomla.zip -L https://joomla.org/latest
unzip -q joomla.zip
rm joomla.zip

php installation/joomla.php install \
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

# --- 5. Configure Joomla ---
echo "--> Configuring Joomla..."
php cli/joomla.php config:set debug=true error_reporting=maximum

# Install extension if available
WEBLINKS_PKG="${WORKSPACE_ROOT}/dist/pkg-weblinks-current.zip"
if [ -f "$WEBLINKS_PKG" ]; then
    php cli/joomla.php extension:install --path="$WEBLINKS_PKG"
    cd $WORKSPACE_ROOT && vendor/bin/robo map /var/www/joomla
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

# --- 7. Codespaces Fix ---
echo "--> Applying Codespaces fix..."
PUBLIC_HOSTNAME="${CODESPACE_NAME}-80.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
echo "127.0.0.1 ${PUBLIC_HOSTNAME}" >> /etc/hosts

# Create minimal PHP fix
cat > $JOOMLA_ROOT/fix.php << 'EOF'
<?php
if (isset($_SERVER['HTTP_HOST']) && $_SERVER['HTTP_HOST'] === 'localhost:80') {
    if (isset($_SERVER['HTTP_X_FORWARDED_HOST'])) {
        $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
        $_SERVER['SERVER_NAME'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
    }
}
EOF

# Include fix in both entry points
cp $JOOMLA_ROOT/fix.php $JOOMLA_ROOT/administrator/fix.php
sed -i '2i require_once __DIR__ . "/fix.php";' $JOOMLA_ROOT/index.php
sed -i '2i require_once __DIR__ . "/../fix.php";' $JOOMLA_ROOT/administrator/index.php


# --- 8. Finalize ---
echo "--> Finalizing setup..."
chown -R www-data:www-data $JOOMLA_ROOT
find $JOOMLA_ROOT -type d -exec chmod 755 {} \;
find $JOOMLA_ROOT -type f -exec chmod 644 {} \;
service apache2 restart

# Save credentials
cat > "${WORKSPACE_ROOT}/login-credentials.txt" << EOF
✅ Setup complete!

Joomla Admin:
  URL: Open 'Web Server' port + /administrator
  Username: $ADMIN_USER
  Password: $ADMIN_PASS

phpMyAdmin:
  URL: Open 'Web Server' port + /phpmyadmin
  Username: root
  Password: $ADMIN_PASS
EOF

echo "--- Setup Complete! Check login-credentials.txt for details ---"
