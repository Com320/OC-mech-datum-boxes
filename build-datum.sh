#!/bin/bash
# This script builds Datum Gateway.
# It clones the datum_gateway repository and compiles it using cmake and make.
# It assumes dependencies are already installed.
# NOTE: This script is intended to be invoked by main.sh and should not be run on its own.

# Global Variables & Settings
SETTINGS_FILE="$(dirname "$0")/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Settings file not found at $SETTINGS_FILE"
    exit 1
fi

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# JSON helper functions for parsing settings.json
read_json_value() {
    # Usage: read_json_value "key" file
    local key="$1"
    local file="$2"
    sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p" "$file"
}

# Get username from settings.json
username=$(grep -o '"username": *"[^"]*"' "$SETTINGS_FILE" | cut -d'"' -f4)
if [ -z "$username" ]; then
    echo -e "${RED}Could not determine username from settings.json. Using default 'bitcoin'.${NC}"
    username="bitcoin"
fi

# Get user's home directory
user_home=$(eval echo ~"$username")
if [ ! -d "$user_home" ]; then
    echo -e "${RED}User home directory for $username not found.${NC}"
    exit 1
fi

# Get logpath from settings.json
logpath=$(read_json_value "logpath" "$SETTINGS_FILE")
if [ ! -d "$logpath" ]; then
    mkdir -p "$logpath" || { echo -e "${RED}Unable to create log directory at $logpath${NC}"; exit 1; }
    chown -R "$username:$username" "$logpath"
fi
LOG_FILE="${logpath}/build_datum.log"

# Log function (writes messages with a timestamp)
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | tee -a "$LOG_FILE"
}

# Main Execution
log "Starting Datum Gateway build process..."

# Create source-code directory
datum_dir="$user_home/datum"
src_dir="$datum_dir/src"
log "Creating directory $src_dir..."
if mkdir -p "$src_dir" 2>>"$LOG_FILE"; then
    log "Directory $src_dir created (or already exists)."
    # Set ownership
    chown -R "$username:$username" "$datum_dir"
else
    log "Failed to create directory $src_dir."
    exit 1
fi

# Move into source-code directory (using su to run as the configured user)
log "Changing directory to $src_dir..."
cd "$src_dir" || { log "Failed to change directory to $src_dir."; exit 1; }

# Clone the datum_gateway repository
log "Cloning datum_gateway repository from GitHub..."
if su - "$username" -c "cd $src_dir && git clone https://github.com/OCEAN-xyz/datum_gateway" 2>>"$LOG_FILE"; then
    log "datum_gateway repository cloned successfully."
else
    log "Failed to clone datum_gateway repository."
    exit 1
fi

# Change directory into the cloned repository
gateway_dir="$src_dir/datum_gateway"
log "Changing directory to datum_gateway..."
cd "$gateway_dir" || { log "Failed to change directory to datum_gateway."; exit 1; }

# Run cmake and make to compile the project (as the configured user)
log "Running cmake..."
if su - "$username" -c "cd $gateway_dir && cmake ." 2>>"$LOG_FILE"; then
    log "cmake completed successfully."
else
    log "cmake failed."
    exit 1
fi

log "Running make..."
if su - "$username" -c "cd $gateway_dir && make" 2>>"$LOG_FILE"; then
    log "make completed successfully."
else
    log "make failed."
    exit 1
fi

# Make sure the binary directory exists
mkdir -p "$datum_dir/bin"
chown -R "$username:$username" "$datum_dir/bin"

# Copy the compiled binary to the bin directory
if cp "$gateway_dir/datum_gateway" "$datum_dir/bin/"; then
    log "Copied datum_gateway binary to $datum_dir/bin/"
    chown "$username:$username" "$datum_dir/bin/datum_gateway"
else
    log "Failed to copy datum_gateway binary."
    exit 1
fi

log "Datum Gateway build process completed."