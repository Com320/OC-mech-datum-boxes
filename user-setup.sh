#!/bin/bash
# This script creates and configures the user defined in settings.json.
# It is intended to be run at the start of the main.sh script.

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Global Variables & Settings
SETTINGS_FILE="$(dirname "$0")/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo -e "${RED}Settings file not found at $SETTINGS_FILE${NC}"
    exit 1
fi

# JSON helper function (using sed for simple flat JSON parsing)
read_json_value() {
    # Usage: read_json_value "key" file
    local key="$1"
    local file="$2"
    sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p" "$file"
}

read_json_bool() {
    # Usage: read_json_bool "key" file
    local key="$1"
    local file="$2"
    value=$(sed -n "s/.*\"$key\": *\(true\|false\).*/\1/p" "$file")
    if [ "$value" == "true" ]; then
        return 0
    else
        return 1
    fi
}

# Ensure running as root/sudo
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root or with sudo privileges.${NC}"
    exit 1
fi

# Read user configuration from settings.json
username=$(grep -o '"username": *"[^"]*"' "$SETTINGS_FILE" | cut -d'"' -f4)

if [ -z "$username" ]; then
    echo -e "${RED}Could not determine username from settings.json.${NC}"
    # Prompt for username if not found in settings
    while true; do
        read -p "Enter username to create: " username
        echo "You entered: $username"
        read -p "Is this correct? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            break
        fi
        echo "Let's try again."
    done
else
    # Confirm the username from settings
    echo -e "Username from settings: ${GREEN}$username${NC}"
    read -p "Do you want to use this username? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        # Let user override the settings value
        while true; do
            read -p "Enter username to create: " new_username
            echo "You entered: $new_username"
            read -p "Is this correct? (y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                username=$new_username
                break
            fi
            echo "Let's try again."
        done
    fi
fi

echo "Using username: $username"

# Check if user exists
if id "$username" &>/dev/null; then
    echo -e "${GREEN}User $username already exists.${NC}"
else
    read_json_bool "create_if_not_exists" "$SETTINGS_FILE"
    if [ $? -eq 0 ]; then
        echo "Creating user $username..."
        useradd -m -s /bin/bash "$username"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}User $username created successfully.${NC}"
        else
            echo -e "${RED}Failed to create user $username. Exiting.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}User $username does not exist and create_if_not_exists is set to false in settings.json. Exiting.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}User setup completed successfully.${NC}"
exit 0