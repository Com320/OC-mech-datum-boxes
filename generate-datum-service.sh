#!/bin/bash

# Source shared utility functions
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging for this script
init_logging "generate_datum_service"

log "Starting Datum service generation script..."

# Get username using the shared function
username=$(get_username)
if [ $? -ne 0 ]; then
    log_display "${RED}Failed to get valid username. Exiting.${NC}"
    exit 1
fi

# Get user's home directory using the shared function
user_home=$(get_home_directory "$username")
if [ $? -ne 0 ]; then
    log_display "${RED}Failed to get home directory. Exiting.${NC}"
    exit 1
fi

log "Using home directory: $user_home"

# Write the content to the service file
log "Creating Datum service file at /usr/lib/systemd/system/datum.service"
cat > /usr/lib/systemd/system/datum.service << EOF
[Unit]
Description=Datum Gateway Service
After=network.target

[Service]
LimitNOFILE=65535
ExecStart=$user_home/datum/bin/datum_gateway --config=$user_home/datum/datum_gateway_config.json
Restart=always
User=$username
Group=$username

[Install]
WantedBy=multi-user.target
EOF

# Check if the operation was successful
if [ $? -eq 0 ]; then
    log_display "${GREEN}File 'datum.service' has been created and user inserted correctly.${NC}"
    log "Service configuration saved to: /usr/lib/systemd/system/datum.service"
    
    # Enable and start the service if requested
    if confirm_prompt "Do you want to enable and start the service now? (y/n): "; then
        log "User chose to enable and start the service"
        log "Running: systemctl daemon-reload"
        systemctl daemon-reload
        log "Running: systemctl enable datum.service"
        systemctl enable datum.service
        log "Running: systemctl start datum.service"
        systemctl start datum.service
        log_display "${GREEN}Service enabled and started.${NC}"
        
        # Check service status
        log "Checking service status..."
        echo "Checking service status..."
        # Capture service status to log file while also showing on screen
        systemctl status datum.service | tee -a "$LOG_FILE"
    else
        log "User chose not to enable and start the service"
        echo "You can manually start the service with: systemctl start datum.service"
    fi
else
    log_display "${RED}An error occurred while creating or editing the file.${NC}"
    exit 1
fi

log "Datum service generation completed."
