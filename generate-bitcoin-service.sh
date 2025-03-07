#!/bin/bash

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Prompt the user for input
while true; do
    read -p "Enter the text to replace 'defaultuser' with: " user_input

    echo "You entered: $user_input"
    read -p "Is this correct? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        break
    fi
    echo "Let's try again."
    echo
done


# Sanity check input
if [ -z "$user_input" ]; then
    echo -e "${RED}User input must be provided. Exiting.${NC}"
    exit 1
fi

# Write the content to the service file with sudo
sudo bash -c "cat > /etc/systemd/system/bitcoin_knots.service" << EOF
[Unit]
Description=Bitcoin Knots Service
After=network.target

[Service]
ExecStart=/usr/local/bin/bitcoind
Restart=always
User=$user_input
Group=$user_input

[Install]
WantedBy=multi-user.target
EOF

# Check if the operation was successful
if [ $? -eq 0 ]; then
    echo -e "${GREEN}File 'bitcoin_knots.service' has been created and user inserted correctly.${NC}"
else
    echo -e "${RED}An error occurred while creating or editing the file.${NC}"
    exit 1
fi
