#!/bin/bash
# Script is part of a larger project, it installs dependencies for the project.
# This script should not be run on its own, this is part of main.sh.
#   It reads settings from a settings.json file in the same directory

# Global Variables & Settings
SETTINGS_FILE="$(dirname "$0")/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Settings file not found at $SETTINGS_FILE"
    exit 1
fi

# JSON helper functions (using sed for simple flat JSON parsing)
read_json_value() {
    # Usage: read_json_value "key" file
    local key="$1"
    local file="$2"
    sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p" "$file"
}

read_json_array() {
    # Usage: read_json_array "key" file
    # It extracts the lines between the [ and ] for the given key
    local key="$1"
    local file="$2"
    sed -n "/\"$key\": *\[/,/\]/p" "$file" | sed '1d;$d'
}

# Read settings from JSON
logpath=$(read_json_value "logpath" "$SETTINGS_FILE")

# Create log directory if it doesn't exist
if [ ! -d "$logpath" ]; then
    mkdir -p "$logpath" || { echo "Unable to create log directory at $logpath"; exit 1; }
fi
LOG_FILE="${logpath}/depend_inst.log"

# Function to log messages with a timestamp
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | tee -a "$LOG_FILE"
}

# Read package list array from settings.json
packages_json=$(read_json_array "packages" "$SETTINGS_FILE")
PACKAGES=()
while read -r line; do
    pkg=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[",]//g')
    if [ -n "$pkg" ]; then
        PACKAGES+=( "$pkg" )
    fi
done <<< "$packages_json"

error_occurred=0

# Main Execution
log "Starting installation process..."

# Update package lists
log "Updating package lists..."
if sudo apt-get update 2>&1 | tee -a "$LOG_FILE"; then
    log "Package lists updated successfully."
else
    log "Failed to update package lists."
    error_occurred=1
fi

# Install packages
log "Installing packages..."
for package in "${PACKAGES[@]}"; do
    log "Installing $package..."
    if sudo apt-get install -y "$package" 2>&1 | tee -a "$LOG_FILE"; then
        log "$package installed successfully."
    else
        log "Failed to install $package."
        error_occurred=1
    fi
done

if [ "$error_occurred" -eq 1 ]; then
    log "Installation process completed, but with errors, see log"
else
    log "Installation process completed."
fi