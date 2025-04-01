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
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# JSON helper function (using sed for simple flat JSON parsing)
read_json_value() {
    # Usage: read_json_value "key" file
    local key="$1"
    local file="$2"
    sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p" "$file"
}

# Read the CPU cores setting (default to 4 if not found)
cpu_cores=$(grep -o '"cpu_cores": *[0-9]*' "$SETTINGS_FILE" | grep -o '[0-9]*')
if [ -z "$cpu_cores" ]; then
    echo -e "${RED}Could not determine cpu_cores from settings.json. Using default '4'.${NC}"
    cpu_cores=4
fi

# Read Bitcoin Knots tag to checkout (default to v28.1.knots20250305 if not found)
bitcoin_knots_tag=$(grep -o '"bitcoin_knots_tag": *"[^"]*"' "$SETTINGS_FILE" | cut -d'"' -f4)
if [ -z "$bitcoin_knots_tag" ]; then
    echo -e "${RED}Could not determine bitcoin_knots_tag from settings.json. Using default 'v28.1.knots20250305'.${NC}"
    bitcoin_knots_tag="v28.1.knots20250305"
fi

# Read signature verification setting (default to true if not found)
verify_signatures=$(grep -o '"verify_signatures": *[^,}]*' "$SETTINGS_FILE" | grep -o '[^:]*$' | tr -d ' ')
if [ -z "$verify_signatures" ]; then
    echo -e "${YELLOW}Could not determine verify_signatures from settings.json. Using default 'true'.${NC}"
    verify_signatures=true
fi

# Read key fingerprint (default if not found)
key_fingerprint=$(grep -o '"key_fingerprint": *"[^"]*"' "$SETTINGS_FILE" | cut -d'"' -f4)
if [ -z "$key_fingerprint" ]; then
    echo -e "${YELLOW}Could not determine key_fingerprint from settings.json. Using default '1A3E761F19D2CC7785C5502EA291A2C45D0C504A'.${NC}"
    key_fingerprint="1A3E761F19D2CC7785C5502EA291A2C45D0C504A"
fi

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

# Verify function for checking git tag signature
verify_git_tag() {
    local repo_path="$1"
    local tag="$2"
    local fingerprint="$3"
    
    log "Verifying signature for tag: $tag"
    
    # Check if we have gnupg installed
    if ! command -v gpg &> /dev/null; then
        log "${RED}Error: GPG is not installed. Please run dependencies.sh first or restart the entire setup process.${NC}"
        return 1
    fi

    # Get the path to the verification script
    local verify_script="$(dirname "$0")/verify-git-tag.sh"
    
    # Ensure the script is executable
    chmod +x "$verify_script"
    
    # Create a log file path that the bitcoin user can write to
    local user_log_file="$user_home/.verify-git-tag.log"
    touch "$user_log_file"
    chown "$username:$username" "$user_log_file"
    
    # Run the verification script as the repository owner, passing the log file path
    su - "$username" -c "$verify_script \"$repo_path\" \"$tag\" \"$fingerprint\" \"$user_log_file\""
    local result=$?
    
    # Copy the content from the user log file to our main log file
    if [ -f "$user_log_file" ]; then
        cat "$user_log_file" >> "$LOG_FILE"
        rm -f "$user_log_file"
    fi
    
    if [ $result -eq 0 ]; then
        log "Signature verification successful for tag: $tag"
        return 0
    else
        log "Signature verification failed for tag: $tag"
        return 1
    fi
}

# Main Execution
log "Starting Bitcoin Knots build process..."
log "Using Bitcoin Knots tag: $bitcoin_knots_tag"
log "Using $cpu_cores CPU cores for build"
if [ "$verify_signatures" = true ]; then
    log "Signature verification is ENABLED"
else
    log "Signature verification is DISABLED"
fi

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

# Checkout the specified tag
log "Checking out tag: $bitcoin_knots_tag..."
if su - "$username" -c "cd $bitcoin_src && git fetch --tags && git checkout $bitcoin_knots_tag" 2>&1 | tee -a "$LOG_FILE"; then
    log "Tag checkout completed successfully."
else
    log "Tag checkout failed. The specified tag may not exist."
    exit 1
fi

# Verify tag signature if enabled
if [ "$verify_signatures" = true ]; then
    if verify_git_tag "$bitcoin_src" "$bitcoin_knots_tag" "$key_fingerprint"; then
        log "Signature verification passed. Proceeding with build."
    else
        log "Signature verification failed. Aborting build for security reasons."
        exit 1
    fi
fi

# Run autogen.sh
log "Running autogen.sh..."
