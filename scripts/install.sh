#!/bin/bash

API_KEY=$1
SECRET_KEY=$2
INSTALL_TYPE=${3:-production} # development | production (defaults to production)
AP_INTERFACE=$4
NETWORK_NODE_AP_IP=192.168.101.1
MQTT_USERNAME=huebot_mqtt
MQTT_PASSWORD=$(openssl rand -base64 10)
INSTALL_DIR=/usr/local/bin

if [[ ! $API_KEY =~ ^\{?[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}\}?$ ]]; then
  echo "Install failed. First arg must be API key (uuid)"
  exit 1;
fi

if [[ ! $SECRET_KEY =~ ^\{?[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}\}?$ ]]; then
  echo "Install failed. Second arg must be secret key (uuid)"
  exit 1;
fi

printf "Disabling interactive prompts..."
sudo sed -i "/^#\$nrconf{restart} = 'i';/ c\$nrconf{restart} = 'a';" /etc/needrestart/needrestart.conf;
printf "Done.\n"

printf "Installing required packages. This could take a while..."
sudo apt-get update && sudo apt-get -y upgrade

sudo apt-get install -y docker \
    docker-compose \
    network-manager \
    dnsmasq \
    jq \
    libnss-mdns # Allow '.local' access
printf "Done.\n"

printf "Configuring user permissioning..."
# Add huebot user to groups
sudo usermod -aG docker,netdev huebot

# Make huebot user sudoer (don't require pw for sudo commands)
echo 'huebot ALL=(ALL:ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers.d/010_huebot-nopasswd
printf "Done.\n"

printf "Create Huebot host db..."
# Create directory for production db (huebot dir created when using install CLI)
mkdir $INSTALL_DIR/huebot/db
printf "Done.\n"

printf "Setting up Mosquitto host requirements..."
mkdir $INSTALL_DIR/mosquitto/data
sudo touch $INSTALL_DIR/mosquitto/data/mosquitto.db
mkdir $INSTALL_DIR/mosquitto/log
sudo touch $INSTALL_DIR/mosquitto/log/mosquitto.log
mkdir $INSTALL_DIR/mosquitto/conf.d
sudo touch $INSTALL_DIR/mosquitto/conf.d/huebot.conf

# MQTT broker credentials
cat <<EOT | sudo tee -a $INSTALL_DIR/mosquitto/config.json
{
    "mqtt_username": "$MQTT_USERNAME",
    "mqtt_password": "$MQTT_PASSWORD"
}
EOT

# give container recursive write access to dir
sudo chown -R 1883:1883 $INSTALL_DIR/mosquitto
printf "Done.\n"

printf "Configuring network settings..."
# Downgrade wpa_supplicant - latest version (2.10) has NM hotspot bug
# https://askubuntu.com/questions/1406149/cant-connect-to-ubuntu-22-04-hotspot
cat <<EOT | sudo tee -a /etc/apt/sources.list
deb http://old-releases.ubuntu.com/ubuntu/ impish main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ impish-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ impish-security main restricted universe multiverse
EOT
sudo apt update
sudo apt --allow-downgrades install -y wpasupplicant=2:2.9.0-21build1

# Enable Network Manager
sudo systemctl enable NetworkManager.service

# Disable netplan
sudo rm /etc/netplan/*
cat <<EOT | sudo tee -a /etc/netplan/netplan-config.yaml
network:
  version: 2
  renderer: NetworkManager
EOT

sudo ufw allow 22 #ssh
sudo ufw allow 80 
sudo ufw allow 1883 #mqtt
sudo ufw allow in on $AP_INTERFACE # AP
sudo ufw --force enable

cat <<EOT | sudo tee -a /etc/NetworkManager/conf.d/00-use-dnsmasq.conf
[main]
dns=dnsmasq
EOT

cat <<EOT | sudo tee -a /etc/NetworkManager/dnsmasq.d/00-dnsmasq-config.conf
interface=$AP_INTERFACE
dhcp-range=192.168.101.2,192.168.101.250,255.255.255.0,24h
local=/huebot/
EOT

sudo hostnamectl set-hostname $API_KEY
sudo sed -i "s/127.0.1.1\s.*/127.0.1.1 ${API_KEY}/g" /etc/hosts

# Setup server dns
cat <<EOT | sudo tee -a /etc/hosts
$NETWORK_NODE_AP_IP hub.huebot
EOT
printf "Done.\n"

printf "Set environment variables..."
# TO DO: Delete mqtt credentials once core reads from config.json
cat <<EOT | sudo tee -a /etc/environment
HUEBOT_API_KEY=${API_KEY}
HUEBOT_SECRET_KEY=${SECRET_KEY}
NETWORK_NODE_AP_IP=${NETWORK_NODE_AP_IP}
MQTT_USERNAME=${MQTT_USERNAME}
MQTT_PASSWORD=${MQTT_PASSWORD}
EOT
printf "Done.\n"

## INSTALL DEVELOPMENT PACKAGES
if [ $INSTALL_TYPE = "development" ]; then
  printf "Installing development packages..."

  sudo apt-get --with-new-pkgs upgrade -y && \
      sudo apt-get full-upgrade -y && \
      sudo add-apt-repository ppa:deadsnakes/ppa -y && \
      sudo apt-get update

  curl -sL https://deb.nodesource.com/setup_18.x | sudo -E bash
  
  sudo apt-get install -yq software-properties-common \
      nodejs \
      sqlite3

  # Set NPM global path
  mkdir ~/.npm-global
  npm config set prefix '~/.npm-global'
  echo "export PATH=~/.npm-global/bin:$PATH" >> ~/.profile  
  source ~/.profile

  # Enable full mosquitto logging in dev mode
  cat <<EOT > $INSTALL_DIR/mosquitto/conf.d/huebot.conf
log_type all
EOT

  printf "Done.\n"
fi

printf "Installing Docker containers and spinning up..."
# Install docker images and start containers so they autostart on reboot
sudo docker-compose -f $INSTALL_DIR/huebot/runner/docker-compose.yml up -d
printf "Done.\n"

echo "************************ INSTALL COMPLETE ************************"
echo ""
echo "Rebooting device"
echo "Login using: ssh huebot@${API_KEY}.local"
echo ""
echo "******************************************************************"

sudo reboot