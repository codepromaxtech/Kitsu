#!/bin/bash

set -e
LOGFILE="/var/log/zou_setup.log"
exec > >(tee -i "$LOGFILE") 2>&1

# Ensure the script is run with sudo
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

trap 'rm -f /tmp/kitsu.tgz' EXIT

echo "Installing dependencies..."
apt-get update
apt-get install -y postgresql postgresql-client postgresql-server-dev-all build-essential redis-server nginx xmlsec1 ffmpeg software-properties-common curl

echo "Installing Python 3.12..."
add-apt-repository ppa:deadsnakes/ppa -y
apt-get update
apt-get install -y python3.12 python3.12-venv python3.12-dev

echo "Setting up Zou user and directories..."
useradd --home /opt/zou zou || true
mkdir -p /opt/zou/backups /opt/zou/previews /opt/zou/tmp /opt/zou/logs
chown -R zou:www-data /opt/zou
chown zou: /opt/zou/backups

echo "Installing Zou in a virtual environment..."
python3.12 -m venv /opt/zou/zouenv
/opt/zou/zouenv/bin/python -m pip install --upgrade pip
/opt/zou/zouenv/bin/python -m pip install zou

echo "Setting up PostgreSQL..."

# Set password for PostgreSQL user
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'Harry@2020';"

# Restart PostgreSQL service
sudo service postgresql restart

# Create the database if it doesn't already exist
if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = 'zoudb';" | grep -q 1; then
    sudo -u postgres psql -c "CREATE DATABASE zoudb;"
    echo "Database zoudb created successfully."
else
    echo "Database zoudb already exists."
fi


# Initialize the database
DB_PASSWORD=Harry@2020 /opt/zou/zouenv/bin/zou init-db

echo "Configuring Redis..."
echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
sysctl -p

echo "Installing Meilisearch..."
echo "deb [trusted=yes] https://apt.fury.io/meilisearch/ /" > /etc/apt/sources.list.d/fury.list
apt-get update
apt-get install -y meilisearch

echo "Creating Meilisearch user and group..."
groupadd meilisearch || true
useradd -g meilisearch meilisearch || true

mkdir -p /opt/meilisearch
chown -R meilisearch:meilisearch /opt/meilisearch

cat > /etc/systemd/system/meilisearch.service <<EOF
[Unit]
Description=Meilisearch search engine
After=network.target

[Service]
User=meilisearch
Group=meilisearch
WorkingDirectory=/opt/meilisearch
ExecStart=/usr/bin/meilisearch --master-key="masterkey"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start meilisearch
systemctl enable meilisearch

# Ensure Meilisearch is running, if not restart and wait
echo "Verifying Meilisearch..."
for i in {1..5}; do
    STATUS=$(systemctl is-active meilisearch)
    if [ "$STATUS" == "active" ]; then
        echo "Meilisearch is active and running."
        break
    else
        echo "Meilisearch is not running, restarting..."
        systemctl restart meilisearch
        sleep 2
    fi
done

# Check Meilisearch API Health
echo "Meilisearch API Health Check: $(curl -s http://127.0.0.1:7700/health)"

echo "Configuring Gunicorn..."
mkdir -p /etc/zou
cat > /etc/zou/gunicorn.conf <<EOF
accesslog = "/opt/zou/logs/gunicorn_access.log"
errorlog = "/opt/zou/logs/gunicorn_error.log"
workers = 3
worker_class = "gevent"
EOF

cat > /etc/systemd/system/zou.service <<EOF
[Unit]
Description=Gunicorn instance to serve the Zou API
After=network.target

[Service]
User=zou
Group=www-data
WorkingDirectory=/opt/zou
Environment="DB_PASSWORD=Harry@2020"
Environment="SECRET_KEY=Shee0quae9ieSohnThaezoh6saes"
Environment="PATH=/opt/zou/zouenv/bin:/usr/bin"
Environment="PREVIEW_FOLDER=/opt/zou/previews"
Environment="TMP_DIR=/opt/zou/tmp"
ExecStart=/opt/zou/zouenv/bin/gunicorn -c /etc/zou/gunicorn.conf -b 127.0.0.1:5000 zou.app:app

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start zou
systemctl enable zou

echo "Configuring Nginx for Zou..."
rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-enabled/zou
sudo rm -f /etc/nginx/sites-available/zou

# Copy the zou file
sudo cp ./zou /etc/nginx/sites-available/zou

# Create a symbolic link to enable the site
sudo ln -s /etc/nginx/sites-available/zou /etc/nginx/sites-enabled/zou

systemctl restart nginx

echo "Deploying Kitsu..."
mkdir -p /opt/kitsu/dist
curl -L -o /tmp/kitsu.tgz $(curl -v https://api.github.com/repos/cgwire/kitsu/releases/latest | grep 'browser_download_url.*kitsu-.*.tgz' | cut -d : -f 2,3 | tr -d \")
tar xvzf /tmp/kitsu.tgz -C /opt/kitsu/dist/
rm /tmp/kitsu.tgz
echo "Initializing Kitsu data..."
DB_PASSWORD=Harry@2020 /opt/zou/zouenv/bin/zou init-data
DB_PASSWORD=Harry@2020 /opt/zou/zouenv/bin/zou reset-search-index

echo "Creating Zou admin user..."
DB_PASSWORD=Harry@2020 /opt/zou/zouenv/bin/zou create-admin --password "Harry@2020" "haripandit@creatfx.com"

echo "Setup complete. Access Kitsu via http://${SERVER_DOMAIN_OR_IP}!"
