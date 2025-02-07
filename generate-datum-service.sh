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
    echo "User input must be provided. Exiting."
    exit 1
fi

# Write the content to the service file with sudo
sudo bash -c "cat > /etc/systemd/system/datum.service" << EOF
[Unit]
Description=Datum Gateway Service
After=network.target

[Service]
LimitNOFILE=65535
ExecStart=/home/$user_input/datum/src/datum_gateway/datum_gateway --config=/home/$user_input/datum/datum_gateway_config.json
Restart=always
User=$user_input
Group=$user_input

[Install]
WantedBy=multi-user.target
EOF

# Check if the operation was successful
if [ $? -eq 0 ]; then
    echo "File 'datum.service' has been created and user inserted correctly."
else
    echo "An error occurred while creating or editing the file."
    exit 1
fi
