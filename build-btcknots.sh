#!/bin/bash
# This script builds Bitcoin Knots with --disable-wallet.
# It assumes dependencies were installed by a previous step.
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
LOG_FILE="${logpath}/build_btcknots.log"

# Log function (writes messages with a timestamp)
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | tee -a "$LOG_FILE"
}

# Main Execution
log "Starting Bitcoin Knots build process..."

# Synchronize packages using pacman
log "Synchronizing build dependencies with pacman..."
if pacman --sync --needed autoconf automake boost gcc git libevent libtool make pkgconf python sqlite 2>&1 | tee -a "$LOG_FILE"; then
    log "Package synchronization completed successfully."
else
    log "Package synchronization failed."
    exit 1
fi

# Clone the bitcoin repository
log "Cloning Bitcoin Knots repository from GitHub..."
if git clone https://github.com/bitcoinknots/bitcoin.git 2>&1 | tee -a "$LOG_FILE"; then
    log "Bitcoin Knots repository cloned successfully."
else
    log "Failed to clone Bitcoin Knots repository."
    exit 1
fi

# Change directory into the repository
log "Changing directory to bitcoin..."
if cd bitcoin; then
    log "Changed directory successfully. Current directory: $(pwd)"
else
    log "Failed to change directory to bitcoin/."
    exit 1
fi

# Run autogen.sh
log "Running autogen.sh..."
if ./autogen.sh 2>&1 | tee -a "$LOG_FILE"; then
    log "autogen.sh completed successfully."
else
    log "autogen.sh failed."
    exit 1
fi

# Run configure with --disable-wallet option
log "Running configure with --disable-wallet..."
if ./configure --disable-wallet 2>&1 | tee -a "$LOG_FILE"; then
    log "Configure completed successfully."
else
    log "Configure failed."
    exit 1
fi

# Run make check
log "Running make check..."
if make check 2>&1 | tee -a "$LOG_FILE"; then
    log "make check completed successfully."
else
    log "make check failed."
    exit 1
fi

log "Bitcoin Knots build process completed."