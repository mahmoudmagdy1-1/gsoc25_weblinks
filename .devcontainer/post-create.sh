#!/bin/bash

# This script runs INSIDE the 'app' container after it's created.
set -e

echo "--- Starting Post-Creation Setup ---"

# --- 0. Wait for Database ---
echo "--> Waiting for database to be ready..."
# This is a simple loop to wait until the 'db' container is accepting connections.
until mysql -h db -u joomla_ut -pjoomla_ut -e "SELECT 1;" test_joomla &> /dev/null; do
    echo "Database is unavailable - sleeping"
    sleep 1
done
echo "--> Database is ready."

# --- 1. Install Project Dependencies ---
echo "--> Installing Composer dependencies..."
composer install

echo "--> Installing NPM dependencies..."
npm install

# --- 2. Build the Weblinks Extension Package ---
echo "--> Building the extension package via Robo..."
if [ -f "vendor/bin/robo" ]; then
    vendor/bin/robo build
else
    echo "Robo build tool not found. Skipping package build."
fi

# --- 3. Download and Install Joomla via CLI ---
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
    --admin-user="jane doe" \
    --admin-username="ci-admin" \
    --admin-password="joomla-17082005" \
    --admin-email="admin@example.org" \
    --db-type="mysqli" \
    --db-host="db" \
    --db-name="test_joomla" \
    --db-user="joomla_ut" \
    --db-pass="joomla_ut" \
    --db-prefix="mysql_"

# --- 4. Configure Joomla and Install Extension ---
echo "--> Setting Joomla to debug mode..."
php -d error_reporting=0 $JOOMLA_ROOT/cli/joomla.php config:set debug=true error_reporting=maximum

WEBLINKS_PKG_PATH="/workspaces/weblinks/dist/pkg-weblinks-current.zip"
echo "--> Installing Weblinks extension from $WEBLINKS_PKG_PATH..."
if [ -f "$WEBLINKS_PKG_PATH" ]; then
    php $JOOMLA_ROOT/cli/joomla.php extension:install --path="$WEBLINKS_PKG_PATH"
else
    echo "Weblink package not found. Skipping installation."
fi

# --- 5. Finalize Permissions ---
echo "--> Setting final file permissions..."
chown -R www-data:www-data $JOOMLA_ROOT

echo ""
echo "---"
echo "✅ Setup complete! Your environment is ready."
echo "---"
