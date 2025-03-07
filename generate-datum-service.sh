# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get username from settings.json
SETTINGS_FILE="$(dirname "$0")/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo -e "${RED}Settings file not found at $SETTINGS_FILE${NC}"
    exit 1
fi

# Get username from settings.json
username=$(grep -o '"username": *"[^"]*"' "$SETTINGS_FILE" | cut -d'"' -f4)
if [ -z "$username" ]; then
    echo -e "${RED}Could not determine username from settings.json.${NC}"
    
    # Prompt the user for input if we can't get it from settings
    while true; do
        read -p "Enter the username for the service: " user_input

        echo "You entered: $user_input"
        read -p "Is this correct? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            username=$user_input
            break
        fi
        echo "Let's try again."
        echo
    done
else
    echo "Using username from settings.json: $username"
    read -p "Is this correct? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        # Let the user override the settings.json value
        while true; do
            read -p "Enter the username for the service: " user_input

            echo "You entered: $user_input"
            read -p "Is this correct? (y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                username=$user_input
                break
            fi
            echo "Let's try again."
            echo
        done
    fi
fi

# Sanity check input
if [ -z "$username" ]; then
    echo -e "${RED}Username must be provided. Exiting.${NC}"
    exit 1
fi

# Check if the user exists
if ! id "$username" &>/dev/null; then
    echo -e "${RED}User $username does not exist. Please create the user first.${NC}"
    exit 1
fi

# Write the content to the service file with sudo
sudo bash -c "cat > /etc/systemd/system/datum.service" << EOF
[Unit]
Description=Datum Gateway Service
After=network.target

[Service]
LimitNOFILE=65535
ExecStart=/home/$username/datum/bin/datum_gateway --config=/home/$username/datum/datum_gateway_config.json
Restart=always
User=$username
Group=$username

[Install]
WantedBy=multi-user.target
EOF

# Check if the operation was successful
if [ $? -eq 0 ]; then
    echo -e "${GREEN}File 'datum.service' has been created and user inserted correctly.${NC}"
    
    # Enable and start the service if requested
    read -p "Do you want to enable and start the service now? (y/n): " start_service
    if [[ "$start_service" == "y" ]]; then
        sudo systemctl daemon-reload
        sudo systemctl enable datum.service
        sudo systemctl start datum.service
        echo -e "${GREEN}Service enabled and started.${NC}"
    else
        echo "You can manually start the service with: sudo systemctl start datum.service"
    fi
else
    echo -e "${RED}An error occurred while creating or editing the file.${NC}"
    exit 1
fi
