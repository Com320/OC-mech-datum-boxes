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
    
    # Import the key if it's not already in the keyring
    if ! gpg --list-keys "$fingerprint" &> /dev/null; then
        log "Importing key with fingerprint: $fingerprint"
        if ! gpg --keyserver keyserver.ubuntu.com --recv-keys "$fingerprint" >> "$LOG_FILE" 2>&1; then
            log "Failed to import key from Ubuntu keyserver, trying keys.openpgp.org..."
            if ! gpg --keyserver keys.openpgp.org --recv-keys "$fingerprint" >> "$LOG_FILE" 2>&1; then
                log "Error: Failed to import key from both keyservers"
                return 1
            fi
        fi
    fi
    
    # Verify the tag using Git's built-in verification
    cd "$repo_path" || { log "Failed to change to repository directory"; return 1; }
    
    # First make sure the tag exists
    if ! git tag -l | grep -q "^$tag$"; then
        log "Error: Tag $tag does not exist in the repository"
        return 1
    fi
    
    # Let Git verify the tag
    log "Verifying tag signature with Git..."
    if git verify-tag "$tag" >> "$LOG_FILE" 2>&1; then
        log "Signature verification successful for tag: $tag"
        return 0
    else
        log "Error: Tag signature verification failed"
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
