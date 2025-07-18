#!/bin/bash
# Script is part of a larger project, it installs dependencies for the project.
# This script should not be run on its own, this is part of main.sh.
#   It reads settings from a settings.json file in the same directory

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging
init_logging "dependencies"

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
log_display "Updating package lists..."
if apt-get update 2>&1 | tee -a "$LOG_FILE"; then
    log_display "Package lists updated successfully."
else
    log_display "Failed to update package lists."
    error_occurred=1
fi

# Install packages
log_display "Installing packages..."
for package in "${PACKAGES[@]}"; do
    log_display "Installing $package..."
    if apt-get install -y "$package" 2>&1 | tee -a "$LOG_FILE"; then
        log_display "$package installed successfully."
    else
        log_display "Failed to install $package."
        error_occurred=1
    fi
done

if [ "$error_occurred" -eq 1 ]; then
    log_display "Installation process completed, but with errors, see log"
    exit 1
else
    log_display "Installation process completed."
fi