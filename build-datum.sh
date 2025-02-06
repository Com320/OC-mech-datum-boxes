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

# JSON helper function (using sed for simple flat JSON parsing)
read_json_value() {
    # Usage: read_json_value "key" file
    local key="$1"
    local file="$2"
    sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p" "$file"
}

# Get logpath from settings.json
logpath=$(read_json_value "logpath" "$SETTINGS_FILE")
if [ ! -d "$logpath" ]; then
    mkdir -p "$logpath" || { echo "Unable to create log directory at $logpath"; exit 1; }
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
log "Creating directory ~/datum/src/..."
if mkdir -p ~/datum/src/ 2>>"$LOG_FILE"; then
    log "Directory ~/datum/src/ created (or already exists)."
else
    log "Failed to create directory ~/datum/src/."
    exit 1
fi

# Move into source-code directory
log "Changing directory to ~/datum/src/..."
if cd ~/datum/src/; then
    log "Changed directory successfully."
    log "Current directory: $(pwd)"
else
    log "Failed to change directory to ~/datum/src/."
    exit 1
fi

# Clone the datum_gateway repository
log "Cloning datum_gateway repository from GitHub..."
if git clone https://github.com/OCEAN-xyz/datum_gateway 2>>"$LOG_FILE"; then
    log "datum_gateway repository cloned successfully."
else
    log "Failed to clone datum_gateway repository."
    exit 1
fi

# Change directory into the cloned repository
log "Changing directory to datum_gateway..."
if cd datum_gateway; then
    log "Changed directory successfully."
    log "Current directory: $(pwd)"
else
    log "Failed to change directory to datum_gateway."
    exit 1
fi

# Run cmake and make to compile the project
log "Running cmake..."
if cmake . 2>>"$LOG_FILE"; then
    log "cmake completed successfully."
else
    log "cmake failed."
    exit 1
fi

log "Running make..."
if make 2>>"$LOG_FILE"; then
    log "make completed successfully."
else
    log "make failed."
    exit 1
fi

log "Datum Gateway build process completed."