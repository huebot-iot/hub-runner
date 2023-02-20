#!/bin/bash

exec 2>&1

API_KEY=$1
SECRET_KEY=$2
INSTALL_TYPE=${3:-production} # development | production (defaults to production)
AP_INTERFACE=$4
NETWORK_NODE_AP_IP=192.168.101.1
MQTT_USERNAME=huebot_mqtt
MQTT_PASSWORD=$(openssl rand -base64 10)

USER_HOME=/home/huebot
INSTALL_DIR=/usr/local/bin
LOG_STATUS=$INSTALL_DIR/huebot/.install
LOG_FILE=$INSTALL_DIR/huebot/install.log

if [ "$EUID" -ne 0 ] ; then
  printf "Must be run as root.\n"
  exit 1
fi

mqtt_config() {
cat > "${INSTALL_DIR}/mosquitto/config.json" <<EOF
{
	"mqtt_username": "$MQTT_USERNAME",
	"mqtt_password": "$MQTT_PASSWORD"
}
EOF
}

supplicant_config() {
cat <<EOF >> /etc/apt/sources.list 
deb http://old-releases.ubuntu.com/ubuntu/ impish main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ impish-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ impish-security main restricted universe multiverse
EOF
}

netplan_config() {
cat > "/etc/netplan/netplan-config.yaml" <<EOF
network:
  version: 2
  renderer: NetworkManager
EOF
}

use_dnsmasq(){
cat > "/etc/NetworkManager/conf.d/00-use-dnsmasq.conf" <<EOF
[main]
dns=dnsmasq
EOF	
}

dnsmasq_config(){
cat > "/etc/NetworkManager/dnsmasq.d/00-dnsmasq-config.conf" <<EOF
interface=$AP_INTERFACE
dhcp-range=192.168.101.2,192.168.101.250,255.255.255.0,24h
local=/huebot/
EOF
}

environment_vars() {
cat <<EOF >> /etc/environment 
HUEBOT_API_KEY=${API_KEY}
HUEBOT_SECRET_KEY=${SECRET_KEY}
NETWORK_NODE_AP_IP=${NETWORK_NODE_AP_IP}
MQTT_USERNAME=${MQTT_USERNAME}
MQTT_PASSWORD=${MQTT_PASSWORD}
EOF
}

runInstall() {

	function error_found {
    		echo '2' > $LOG_STATUS
    		printf "\n\n"
    		printf "#### ERROR ####\n"
    		printf "There was an error detected during the install. Please review the log at /var/log/huebot/huebot_install.log\n"
    		exit 1
  	}
	
	if [ ! -f $LOG_STATUS ] ; then
		if ! touch $LOG_STATUS ; then
			printf "Failed: Error while trying to create %s.\n" "$LOG_STATUS"
			error_found
		fi
	else 
		INSTALL_STATUS=$(<$LOG_STATUS)
		if [ $INSTALL_STATUS == 0 ]; then
			printf "Huebot already installed.\n"
			exit 1
		fi
	fi

	echo '1' > $LOG_STATUS
	
	# Remove stale install log file if found
	if [ -f $LOG_FILE ] ; then
		if ! rm $LOG_FILE >> $LOG_FILE 2>&1 ; then
			printf "Failed to remove %s.\n" "$LOG_FILE"
			error_found
		fi
	fi
	
	# Create new install log file
	
	if ! touch $LOG_FILE >> $LOG_FILE 2>&1 ; then
		printf "Failed to create %s.\n" "$LOG_FILE"
		error_found
	fi

	printf "Disabling interactive prompts..."
	if ! sed -i "/^#\$nrconf{restart} = 'i';/ c\$nrconf{restart} = 'a';" /etc/needrestart/needrestart.conf >> $LOG_FILE 2>&1; then
		printf "Failed to disable interactive prompt\n"
		error_found
	fi
	printf "Done.\n"

	printf "Installing required packages. This could take a while..."

	if ! apt-get update >> $LOG_FILE 2>&1 ; then
     		printf "Update failed"
		error_found
	fi

	if ! apt-get -y upgrade >> $LOG_FILE 2>&1 ; then 
		printf "Upgrade failed"
		error_found
	fi

	PACKAGES=$(apt-get install -y docker \
		docker-compose \
    		network-manager \
    		dnsmasq \
    		jq \
    		libnss-mdns >> $LOG_FILE 2>&1)
	
	if ! $PACKAGES ; then
		printf "Install packages failed\n"
		error_found
	fi
	printf "Done.\n"

	printf "Set user permissions..."
	if ! usermod -aG docker,netdev huebot ;  then
		printf "Set user groups failed"
		error_found
	fi


	SUDOER_TEXT='huebot ALL=(ALL:ALL) NOPASSWD:ALL'
	SUDOER_FILE=/etc/sudoers.d/010_huebot-nopasswd
	if [ -f "$SUDOER_FILE" ]; then
		if grep -q "$SUDOER_TEXT" "$SUDOER_FILE" >> $LOG_FILE 2>&1 ; then
			printf "Sudoer text already exists..."
		else
			SET_SUDOER=$(echo $SUDOER_TEXT | tee -a $SUDOER_FILE >> $LOG_FILE 2>&1)
			if ! $SET_SUDOER ; then 
				printf "Set user as sudoer failed"
				error_found
			fi
		fi
	else
		SET_SUDOER=$(echo $SUDOER_TEXT | tee -a $SUDOER_FILE >> $LOG_FILE 2>&1)
		if ! $SET_SUDOER ; then 
			printf "Set user as sudoer failed"
			error_found
		fi
	fi
	printf "Done.\n"

	printf "Create host db dir..."
	HOST_DB_DIR=$INSTALL_DIR/huebot/db
	if [ -d "${HOST_DB_DIR}" ] ; then
		printf "Already exists..."
	else
		if ! mkdir "${HOST_DB_DIR}" ; then
			printf "Failed: Error while trying to create %s.\n" "${HOST_DB_DIR}"
			error_found
		fi
	fi
	printf "Done.\n"

	printf "Setting up Mosquitto host configuration..."
	MQTT_DIR=$INSTALL_DIR/mosquitto

	if [ ! -d "${MQTT_DIR}" ] ; then
		if ! mkdir "${MQTT_DIR}" ; then
			printf "Failed: Error while trying to create %s.\n" "${MQTT_DIR}"
			error_found
		fi
	fi

	if [ ! -d "${MQTT_DIR}/data" ] ; then
		if ! mkdir "${MQTT_DIR}/data" ; then
			printf "Failed: Error while trying to create %s.\n" "${MQTT_DIR}/data"
			error_found
		fi
	fi

	if [ ! -f "${MQTT_DIR}/data/mosquitto.db" ] ; then
		if ! touch $MQTT_DIR/data/mosquitto.db ; then
			printf "Failed: Error while trying to create %s.\n" "${MQTT_DIR}/data/mosquitto.db"
			error_found
		fi
	fi

	if [ ! -d "${MQTT_DIR}/log" ] ; then
		if ! mkdir "${MQTT_DIR}/log" ; then
			printf "Failed: Error while trying to create %s.\n" "${MQTT_DIR}/log"
			error_found
		fi
	fi

	if [ ! -f "${MQTT_DIR}/log/mosquitto.log" ] ; then
		if ! touch $MQTT_DIR/log/mosquitto.log ; then
			printf "Failed: Error while trying to create %s.\n" "${MQTT_DIR}/log/mosquitto.log"
			error_found
		fi
	fi

	if [ ! -d "${MQTT_DIR}/conf.d" ] ; then
		if ! mkdir "${MQTT_DIR}/conf.d" ; then
			printf "Failed: Error while trying to create %s.\n" "${MQTT_DIR}/conf.d"
			error_found
		fi
	fi

	if [ ! -f "${MQTT_DIR}/conf.d/huebot.conf" ] ; then
		if ! touch $MQTT_DIR/conf.d/huebot.conf ; then
			printf "Failed: Error while trying to create %s.\n" "${MQTT_DIR}/conf.d/huebot.conf"
			error_found
		fi
	fi

	if [ ! -f "${MQTT_DIR}/config.json" ] ; then
		if ! mqtt_config >> $LOG_FILE 2>&1 ; then
			printf "Failed: Error while trying to create %s.\n" "${MQTT_DIR}/config.json"
			error_found
		fi
	fi

	if [ $(chown -R 1883:1883 "$MQTT_DIR") ] ; then 
		printf "Failed: Error while trying to chown %s.\n" "${MQTT_DIR}"
		error_found
	fi
	printf "Done.\n"


	printf "Configuring network settings..."
	
	# Downgrade wpa_supplicant - latest version (2.10) has NM hotspot bug
	# https://askubuntu.com/questions/1406149/cant-connect-to-ubuntu-22-04-hotspot
	# Note: not bulletproof but we will test to see if one line is found in file to determine
	# If this step is already done
	OLD_RELEASE_LINE="deb http://old-releases.ubuntu.com/ubuntu/ impish main restricted universe multiverse"
	if ! grep -q "$OLD_RELEASE_LINE" "/etc/apt/sources.list" >> $LOG_FILE 2>&1 ; then
		if ! supplicant_config >> $LOG_FILE 2>&1 ; then
			printf "Failed: Error while trying add \"old-releases\" repository to %s.\n" "/etc/apt/sources.list"
			error_found
		fi
	fi

	if ! apt-get update >> $LOG_FILE 2>&1 ; then
     	printf "Update failed\n"
		error_found
	fi

	if ! apt --allow-downgrades install -y wpasupplicant=2:2.9.0-21build1 >> $LOG_FILE 2>&1 ; then
     	printf "Update failed\n"
		error_found
	fi

	if ! systemctl enable NetworkManager.service >> $LOG_FILE 2>&1 ; then
		printf "Failed to enable NetworkManager\n"
		error_found
	fi

	if ! rm /etc/netplan/* >> $LOG_FILE 2>&1 ; then
		printf "Failed to recursively delete netplan dir\n"
		error_found
	fi

	if ! netplan_config >> $LOG_FILE 2>&1 ; then
		printf "Failed: Error while trying to set netplan config in %s.\n" "/etc/netplan/netplan-config.yaml"
		error_found
	fi

	if ! ufw allow 22,80,1883/tcp >> $LOG_FILE 2>&1 ; then
		printf "Failed: ufw allow 22,80,1883/tcp.\n"
		error_found
	fi

	if ! ufw allow in on $AP_INTERFACE >> $LOG_FILE 2>&1 ; then
		printf "Failed: ufw allow in on %s.\n" "${AP_INTERFACE}"
		error_found
	fi

	if ! ufw --force enable >> $LOG_FILE 2>&1 ; then
		printf "Failed: ufw --force enable.\n"
		error_found
	fi

	NM_DNSMASQ_FILE="/etc/NetworkManager/conf.d/00-use-dnsmasq.conf"
	if [ ! -f $NM_DNSMASQ_FILE ] ; then
		if ! use_dnsmasq >> $LOG_FILE 2>&1 ; then
			printf "Failed: Error while trying to create %s.\n" "${NM_DNSMASQ_FILE}"
			error_found
		fi
	fi

	DNSMASQ_CONFIG_FILE="/etc/NetworkManager/dnsmasq.d/00-dnsmasq-config.conf"
	if [ ! -f $DNSMASQ_CONFIG_FILE ] ; then
		if ! dnsmasq_config >> $LOG_FILE 2>&1 ; then
			printf "Failed: Error while trying to create %s.\n" "${DNSMASQ_CONFIG_FILE}"
			error_found
		fi
	fi

	HOST_FILE="/etc/hosts"
	if ! grep -q "$API_KEY" "$HOST_FILE" >> $LOG_FILE 2>&1 ; then
		if ! sed -i "s/127.0.1.1\s.*/127.0.1.1 ${API_KEY}/g" $HOST_FILE >> $LOG_FILE 2>&1 ; then
			printf "Failed: Error while trying to set %s as hostname in %s.\n" "${API_KEY}" "${HOST_FILE}"
			error_found
		fi
	fi

	if ! grep -q "$NETWORK_NODE_AP_IP" "$HOST_FILE" >> $LOG_FILE 2>&1 ; then
		HUB_DNS=$(echo "${NETWORK_NODE_AP_IP} hub.huebot" >> $HOST_FILE)
		if ! $HUB_DNS ; then 
			printf "Failed: Error while setting MQTT hostname to hub.huebot"
			error_found
		fi
	fi

	printf "Done.\n"

	printf "Set environment variables..."

	# Note: like "old-releases" above, we will just check one value to determine if this task is done
	if ! grep -q "$API_KEY" "/etc/environment" >> $LOG_FILE 2>&1 ; then
		if ! environment_vars >> $LOG_FILE 2>&1 ; then
			printf "Failed: Error when attempting to set environment variables\n"
			error_found
		fi
	fi

	printf "Done.\n"


	if [ $INSTALL_TYPE = "development" ]; then
		printf "Installing development packages..."

		if ! apt-get --with-new-pkgs upgrade -y >> $LOG_FILE 2>&1; then 
			printf "Failed: Error running apt-get --with-new-pkgs upgrade\n"
			error_found
		fi

		if ! apt-get full-upgrade -y >> $LOG_FILE 2>&1; then 
			printf "Failed: Error running apt-get full-upgrade\n"
			error_found
		fi

		if ! add-apt-repository ppa:deadsnakes/ppa -y >> $LOG_FILE 2>&1; then 
			printf "Failed: Error running add-apt-repository ppa:deadsnakes/ppa\n"
			error_found
		fi

		if ! apt-get update >> $LOG_FILE 2>&1; then 
			printf "Failed: Error running apt-get update\n"
			error_found
		fi

		NODE_DISTRO=$(curl -sL https://deb.nodesource.com/setup_18.x | bash >> $LOG_FILE 2>&1)
		if ! $NODE_DISTRO ; then 
			printf "Failed: Error retrieving NodeJS installation script\n"
			error_found
		fi

		DEV_PACKAGES=$(apt-get install -yq software-properties-common \
			nodejs \
			sqlite3 >> $LOG_FILE 2>&1)
		
		if ! $DEV_PACKAGES ; then
			printf "Failed: Error installing development packages\n"
			error_found
		fi


		NPM_GLOBAL_DIR=$USER_HOME/.npm-global
		if [ ! -d $NPM_GLOBAL_DIR ] ; then
			
			if ! mkdir $NPM_GLOBAL_DIR ; then
				printf "Failed: Error while trying to create %s.\n" "${NPM_GLOBAL_DIR}"
				error_found
			fi

			if ! npm config set prefix "$NPM_GLOBAL_DIR" >> $LOG_FILE 2>&1 ; then
				printf "Failed: Error while running \"npm config set prefix %s\".\n" "${NPM_GLOBAL_DIR}"
				error_found
			fi

			SET_NPM_GLOBAL_PATH=$(echo "export PATH=$NPM_GLOBAL_DIR/bin:$PATH" >> $USER_HOME/.profile)
			if ! $SET_NPM_GLOBAL_PATH >> $LOG_FILE 2>&1 ; then 
				printf "Failed: Error while setting NPM global path.\n"
				error_found
			fi

			if ! source $USER_HOME/.profile >> $LOG_FILE 2>&1 ; then 
				printf "Failed: Error while sourcing $USER_HOME/.profile.\n"
				error_found
			fi

		fi

		DEV_MQTT_LOG_TYPE="log_type all"
		if ! grep -q "$DEV_MQTT_LOG_TYPE" "$MQTT_DIR/conf.d/huebot.conf" >> $LOG_FILE 2>&1 ; then
			SET_LOG_TYPE=$(echo $DEV_MQTT_LOG_TYPE >> "$MQTT_DIR/conf.d/huebot.conf")
			if ! $SET_LOG_TYPE >> $LOG_FILE 2>&1 ; then 
				printf "Failed: Error while setting Mosquitto log_type all"
				error_found
			fi
		fi

	
		printf "Done.\n"
	fi

	printf "Installing Docker containers and spinning up..."
	if ! docker-compose -f $INSTALL_DIR/huebot/runner/docker-compose.yml up -d >> $LOG_FILE 2>&1 ; then
		printf "Failed: Error while pulling/starting Docker containers"
		error_found
	fi
	printf "Done.\n"

	echo '0' > $LOG_STATUS

	printf "\n\n\n************************ INSTALL COMPLETE ************************\n\n\n"
	printf "Rebooting device\n"
	printf "Login using: ssh huebot@%s.local\n" "${API_KEY}"
	printf "Install log: %s\n" "$LOG_FILE"
	printf "\n\n******************************************************************\n\n\n"
	
	reboot
}


runInstall
