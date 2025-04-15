#!/bin/bash
# This script builds Datum Gateway.
# It clones the datum_gateway repository and compiles it using cmake and make.
# It assumes dependencies are already installed.
# NOTE: This script is intended to be invoked by main.sh and should not be run on its own.

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging
init_logging "build-datum"

# Get username from settings.json
username=$(read_json_value "username" "$SETTINGS_FILE")
if [ -z "$username" ]; then
    log_display "${RED}Could not determine username from settings.json. Using default 'bitcoin'.${NC}"
    username="bitcoin"
    log "Using default username: $username"
fi

# Get user's home directory
user_home=$(eval echo ~"$username")
if [ ! -d "$user_home" ]; then
    log_display "${RED}User home directory for $username not found.${NC}"
    exit 1
fi

# Main Execution
log_display "Starting Datum Gateway build process..."

# Create source-code directory
datum_dir="$user_home/datum"
src_dir="$datum_dir/src"
log_display "Creating directory $src_dir..."
if mkdir -p "$src_dir" 2>>"$LOG_FILE"; then
    log_display "Directory $src_dir created (or already exists)."
    # Set ownership
    chown -R "$username:$username" "$datum_dir"
else
    log_display "${RED}Failed to create directory $src_dir.${NC}"
    exit 1
fi

# Move into source-code directory (using su to run as the configured user)
log_display "Changing directory to $src_dir..."
cd "$src_dir" || { log_display "${RED}Failed to change directory to $src_dir.${NC}"; exit 1; }

# Clone the datum_gateway repository
log_display "Cloning datum_gateway repository from GitHub..."
if su - "$username" -c "cd $src_dir && git clone https://github.com/OCEAN-xyz/datum_gateway" 2>>"$LOG_FILE"; then
    log_display "datum_gateway repository cloned successfully."
else
    log_display "${RED}Failed to clone datum_gateway repository.${NC}"
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