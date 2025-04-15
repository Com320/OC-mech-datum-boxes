#!/bin/bash
# This script creates and configures the user defined in settings.json.
# It is intended to be run at the start of the main.sh script.

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging
init_logging "user-setup"

# Ensure running as root/sudo
if [ "$(id -u)" -ne 0 ]; then
    log_display "${RED}This script must be run as root or with sudo privileges.${NC}"
    exit 1
fi

# Read user configuration from settings.json
username=$(read_json_value "username" "$SETTINGS_FILE")

if [ -z "$username" ]; then
    log_display "${RED}Could not determine username from settings.json.${NC}"
    # Prompt for username if not found in settings
    while true; do
        read -p "Enter username to create: " username
        log_display "You entered: $username"
        read -p "Is this correct? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            log "User confirmed username: $username"
            break
        fi
        log_display "Let's try again."
    done
else
    # Confirm the username from settings
    log_display "Username from settings: ${GREEN}$username${NC}"
    read -p "Do you want to use this username? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        log "User chose to override username from settings"
        # Let user override the settings value
        while true; do
            read -p "Enter username to create: " new_username
            log_display "You entered: $new_username"
            read -p "Is this correct? (y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                username=$new_username
                log "User confirmed new username: $username"
                break
            fi
            log_display "Let's try again."
        done
    else
        log "User confirmed using username from settings: $username"
    fi
fi

log_display "Using username: $username"

# Check if user exists
if id "$username" &>/dev/null; then
    log_display "${GREEN}User $username already exists.${NC}"
else
    # Using read_json_bool defined in utils.sh
    if read_json_bool "create_if_not_exists" "$SETTINGS_FILE"; then
        log_display "Creating user $username..."
        useradd -m -s /bin/bash "$username"
        if [ $? -eq 0 ]; then
            log_display "${GREEN}User $username created successfully.${NC}"
        else
            log_display "${RED}Failed to create user $username. Exiting.${NC}"
            exit 1
        fi
    else
        log_display "${RED}User $username does not exist and create_if_not_exists is set to false in settings.json. Exiting.${NC}"
        exit 1
    fi
fi

log_display "${GREEN}User setup completed successfully.${NC}"
exit 0