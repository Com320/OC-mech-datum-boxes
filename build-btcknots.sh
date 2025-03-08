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

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# JSON helper function (using sed for simple flat JSON parsing)
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
if [[ "$logpath" != /* ]]; then
    # If logpath is not absolute, prepend user's home directory
    logpath="$user_home/$logpath"
fi

# Create log directory and set ownership
mkdir -p "$logpath"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create log directory at $logpath${NC}"
    exit 1
fi
chown -R "$username:$username" "$logpath"

LOG_FILE="${logpath}/build_btcknots.log"

# Log function (writes messages with a timestamp)
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | tee -a "$LOG_FILE"
}

# Main Execution
log "Starting Bitcoin Knots build process..."

# Create directories
bitcoin_dir="$user_home/bitcoin"
src_dir="$bitcoin_dir/src"
bin_dir="$bitcoin_dir/bin"

log "Creating directories..."
mkdir -p "$src_dir"
mkdir -p "$bin_dir"
chown -R "$username:$username" "$bitcoin_dir"

# Move into source-code directory
log "Changing directory to $src_dir..."
cd "$src_dir" || { log "Failed to change directory to $src_dir."; exit 1; }

# Install dependencies if on Debian/Ubuntu
if [ -f /etc/debian_version ]; then
    log "Installing build dependencies for Debian/Ubuntu..."
    apt-get update
    apt-get install -y build-essential libtool autotools-dev automake pkg-config bsdmainutils python3 libevent-dev libboost-dev libsqlite3-dev libminiupnpc-dev libnatpmp-dev libzmq3-dev systemtap-sdt-dev
else
    # Try to use pacman if on Arch-based system
    if command -v pacman >/dev/null 2>&1; then
        log "Synchronizing build dependencies with pacman..."
        if pacman --sync --needed autoconf automake boost gcc git libevent libtool make pkgconf python sqlite 2>&1 | tee -a "$LOG_FILE"; then
            log "Package synchronization completed successfully."
        else
            log "Package synchronization failed."
            exit 1
        fi
    else
        log "Warning: Unknown package manager. You may need to install dependencies manually."
    fi
fi

# Clone the bitcoin repository
log "Cloning Bitcoin Knots repository from GitHub..."
if su - "$username" -c "cd $src_dir && git clone https://github.com/bitcoinknots/bitcoin.git" 2>&1 | tee -a "$LOG_FILE"; then
    log "Bitcoin Knots repository cloned successfully."
else
    log "Failed to clone Bitcoin Knots repository."
    exit 1
fi

# Change directory into the repository
bitcoin_src="$src_dir/bitcoin"
log "Changing directory to bitcoin..."
cd "$bitcoin_src" || { log "Failed to change directory to bitcoin/"; exit 1; }

# Run autogen.sh
log "Running autogen.sh..."
if su - "$username" -c "cd $bitcoin_src && ./autogen.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log "autogen.sh completed successfully."
else
    log "autogen.sh failed."
    exit 1
fi

# Run configure with --disable-wallet option
log "Running configure with --disable-wallet..."
if su - "$username" -c "cd $bitcoin_src && ./configure --disable-wallet --prefix=$bitcoin_dir" 2>&1 | tee -a "$LOG_FILE"; then
    log "Configure completed successfully."
else
    log "Configure failed."
    exit 1
fi

# Run make
log "Running make..."
if su - "$username" -c "cd $bitcoin_src && make" 2>&1 | tee -a "$LOG_FILE"; then
    log "make completed successfully."
else
    log "make failed."
    exit 1
fi

# Install to the bin directory
log "Installing binaries..."
if su - "$username" -c "cd $bitcoin_src && make install" 2>&1 | tee -a "$LOG_FILE"; then
    log "Installation completed successfully."
else
    log "Installation failed."
    exit 1
fi

# Create a symlink in /usr/local/bin for system-wide accessibility
log "Creating symlink in /usr/local/bin..."
if ln -sf "$bitcoin_dir/bin/bitcoind" /usr/local/bin/bitcoind 2>&1 | tee -a "$LOG_FILE"; then
    log "Symlink created successfully."
else
    log "Failed to create symlink."
    exit 1
fi

log "Bitcoin Knots build process completed."