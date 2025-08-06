#!/bin/bash

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging
init_logging "bitcoin-conf-generator"

# Get username from settings.json
username=$(read_json_value "user.username" "$SETTINGS_FILE")
if [ -z "$username" ]; then
    log_display "${RED}Could not determine username from settings.json.${NC}"
    username="bitcoin"  # Default username
    log "Using default username: $username"
fi

# Get user's home directory
user_home=$(eval echo ~"$username")
if [ ! -d "$user_home" ]; then
    log_display "${RED}User home directory for $username not found.${NC}"
    exit 1
fi

# Check for RPC info file
rpcinfo_file="$user_home/rpcinfo.bin"
if [ -f "$rpcinfo_file" ]; then
    log_display "${GREEN}Found RPC authentication info:${NC}"
    # Extract the line that starts with "rpcauth="
    rpcauth_line=$(grep "^rpcauth=" "$rpcinfo_file")
    if [ -n "$rpcauth_line" ]; then
        # Extract just the value after "rpcauth="
        rpcauth_value=$(echo "$rpcauth_line" | cut -d'=' -f2)
        log_display "${GREEN}$rpcauth_line${NC}"
        default_rpcauth="$rpcauth_value"
    else
        log_display "${RED}Could not find rpcauth line in $rpcinfo_file${NC}"
        default_rpcauth="username:salt$hash"
    fi
else
    log_display "${RED}RPC authentication info not found. Run generate-rpcauth.sh first.${NC}"
    default_rpcauth="username:salt$hash"
fi

# Function to get user input with default value
get_input() {
    local prompt="$1"
    local default="$2"
    
    # Show the prompt
    read -p "$prompt (default: $default): " input
    
    # If input is empty, use the default
    local result="${input:-$default}"
    
    # Log the input for reference
    log "Input for '$prompt': $result (default was: $default)"
    
    # Return the result
    echo "$result"
}

# Function to handle rpcauth input specifically
get_rpcauth_input() {
    local default_value="$1"
    
    # Special handling for rpcauth to ensure it's not empty
    read -p "Enter value for 'rpcauth' (default: $default_value): " input
    
    # Always use default if empty input
    if [ -z "$input" ]; then
        log "Using default rpcauth value: $default_value"
        echo "$default_value"
    else
        log "User entered custom rpcauth value"
        echo "$input"
    fi
}

# Function to confirm user input
confirm_input() {
    echo "$1"
    read -p "Is this correct? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        log "User chose to edit the configuration"
        return 1
    fi
    log "User confirmed the configuration"
    return 0
}


# Get default values from settings.json
default_conf=$(read_json_value "bitcoin.default_conf" "$SETTINGS_FILE")
if [ -z "$default_conf" ]; then
    default_conf="/etc/bitcoin/bitcoin.conf"
    log_display "${YELLOW}No default_conf found in settings.json, using $default_conf${NC}"
fi

default_data=$(read_json_value "bitcoin.default_data" "$SETTINGS_FILE")
if [ -z "$default_data" ]; then
    default_data="/var/lib/bitcoind"
    log_display "${YELLOW}No default_data found in settings.json, using $default_data${NC}"
fi

# Show current user being used
log_display "Using configuration for user: ${GREEN}$username${NC}"
log_display "Home directory: ${GREEN}$user_home${NC}"
log_display "Using system locations by default for improved compatibility with systemd services"

# Prompt the user for their inputs
while true; do
    user_input1=$(get_input "Enter location for bitcoin.conf" "$default_conf")
    user_input2=$(get_input "Enter location for data" "$default_data")
    user_input3=$(get_input "Enter value for 'prune'" "550")
    user_input4=$(get_input "Enter value for 'dbcache'" "100")
    user_input5=$(get_rpcauth_input "$default_rpcauth")
    
    echo "You entered the following values:"
    echo "Location for bitcoin.conf: $user_input1"
    echo "Location for data: $user_input2"
    echo "Value for 'prune': $user_input3"
    echo "Value for 'dbcache': $user_input4"
    echo "Value for 'rpcauth': $user_input5"

    # Always set conf_file using failsafe logic
    if [[ "$user_input1" == */bitcoin.conf ]]; then
        conf_file="$user_input1"
    else
        conf_file="$user_input1/bitcoin.conf"
    fi

    # If user changed from default_conf, write back to settings.json
    if [ "$user_input1" != "$default_conf" ]; then
        update_json_value "bitcoin.default_conf" "$conf_file" "$SETTINGS_FILE"
        log "Updated settings.json: bitcoin.default_conf set to $conf_file"
    fi
    # If user changed from default_data, write back to settings.json
    if [ "$user_input2" != "$default_data" ]; then
        update_json_value "bitcoin.default_data" "$user_input2" "$SETTINGS_FILE"
        log "Updated settings.json: bitcoin.default_data set to $user_input2"
    fi

    confirm_input "Are these values correct?"
    if [ $? -eq 0 ]; then
        break
    fi
    log_display "Let's try again."
    log_display ""
done

# Create directory for the bitcoin.conf file if it doesn't exist
log "bitcoin.conf will be created at: $conf_file"
conf_dir=$(dirname "$conf_file")
if [ ! -d "$conf_dir" ]; then
    sudo mkdir -p "$conf_dir"
    if [[ "$conf_dir" == "/etc/bitcoin" ]]; then
        # System directory should be root:username with stricter permissions
        sudo chown -R root:"$username" "$conf_dir"
        sudo chmod 750 "$conf_dir"
        log "Created system bitcoin config directory with root:$username ownership"
    else
        # User directory with standard permissions
        sudo chown -R "$username:$username" "$conf_dir"
        sudo chmod 700 "$conf_dir"
        log "Created user bitcoin config directory with $username:$username ownership"
    fi
fi

# Create the data directory if it doesn't exist
if [ ! -d "$user_input2" ]; then
    sudo mkdir -p "$user_input2"
    if [[ "$user_input2" == "/var/lib/bitcoind" ]]; then
        # System data directory should be username:username
        sudo chown -R "$username:$username" "$user_input2"
        sudo chmod 750 "$user_input2"
        log "Created system bitcoin data directory with $username:$username ownership"
    else
        # User data directory
        sudo chown -R "$username:$username" "$user_input2"
        sudo chmod 700 "$user_input2"
        log "Created user bitcoin data directory with $username:$username ownership"
    fi
fi

# Create or overwrite bitcoin.conf
log "Writing bitcoin.conf with the following values:"
log "  - Config location: $conf_file"
log "  - Data directory: $user_input2"
log "  - Prune value: $user_input3"
log "  - DB Cache: $user_input4"
log "  - RPC Auth: $user_input5"

sudo bash -c "cat > $conf_file" << EOF
datadir=$user_input2
upnp=0
listen=1
noirc=0
txindex=0
daemon=0
server=1
rpcallowip=127.0.0.0/8
rpcport=28332
rpctimeout=30
testnet=0
rpcthreads=64
rpcworkqueue=64
logtimestamps=1
logips=1
blockprioritysize=0
blockmaxsize=3985000
blockmaxweight=3985000
blocknotify=killall -USR1 datum_gateway
maxconnections=40
maxmempool=1000
blockreconstructionextratxn=1000000
prune=$user_input3
maxorphantx=50000
assumevalid=000000000000000000014b9196b45c6641432d600fc43ae891fce1cd25620500
dbcache=$user_input4
rpcauth=$user_input5
EOF

# Set ownership
chown "$username:$username" "$conf_file"

# Set permissions to ensure bitcoind can read the file when run by systemd
# chmod 600 (owner read-write only) is appropriate for config files with credentials
chmod 600 "$conf_file"
log "Set permissions on bitcoin.conf to 600 (owner read-write only)"

# Check if the operation was successful
if [ $? -eq 0 ]; then
    log_display "${GREEN}File 'bitcoin.conf' has been created at $conf_file successfully.${NC}"
else
    log_display "${RED}An error occurred while creating the file.${NC}"
    exit 1
fi

# Check if user-selected conf exists
if [ -f "$conf_file" ]; then
    log_display "bitcoin.conf file found at $conf_file."
else
    log_display "${RED}Error: bitcoin.conf file not found at $conf_file.${NC}"
    exit 1
fi

# Create an alias (symlink) from conf_file to user_input2
if ln -sfn "$conf_file" "$user_input2"; then
    log_display "${GREEN}Symlink created from $conf_file -> $user_input2.${NC}"
else
    log_display "${RED}Error: Failed to create symlink from $conf_file to $user_input2.${NC}"
    exit 1
fi


# Get user's home directory
user_home=$(get_home_directory "$username")
bitcoin_dir="$user_home/.bitcoin"

# Ask user if they want bitcoin-cli to work without specifying $user_input2, and handle .bitcoin accordingly
log_display "${YELLOW}Would you like bitcoin-cli to work without specifying the datadir argument?${NC}"
log_display "${YELLOW}If you choose yes, this script will:\n  1. Rename any existing $bitcoin_dir directory or symlink to a backup with a timestamp (e.g., $bitcoin_dir.backup_YYYYMMDD_HHMMSS).\n  2. Create a symlink from $user_input2 to $bitcoin_dir, so bitcoin-cli and related tools will use $user_input2 by default.${NC}"
log_display "${RED}IMPORTANT: This does NOT delete your data, but the original $bitcoin_dir will no longer be used by default. If this is a new installation, $bitcoin_dir should not contain any critical information.${NC}"

read -p "Do you want to set up bitcoin-cli to work without specifying --datadir? (y/n): " setup_bitcoin_symlink
if [[ "$setup_bitcoin_symlink" == "y" ]]; then
    if [ -L "$bitcoin_dir" ] || [ -d "$bitcoin_dir" ]; then
        timestamp=$(date +%Y%m%d_%H%M%S)
        new_bitcoin_dir="$bitcoin_dir.backup_$timestamp"
        if mv "$bitcoin_dir" "$new_bitcoin_dir"; then
            log_display "${YELLOW}Renamed existing $bitcoin_dir to $new_bitcoin_dir${NC}"
        else
            log_display "${RED}Error: Failed to rename $bitcoin_dir to $new_bitcoin_dir${NC}"
            exit 1
        fi
    else
        log_display "No existing $bitcoin_dir directory or symlink to rename."
    fi
    # Create the symlink
    if ln -sfn "$user_input2" "$bitcoin_dir"; then
        log_display "${GREEN}Symlink created: $bitcoin_dir -> $user_input2${NC}"
    else
        log_display "${RED}Error: Failed to create symlink from $bitcoin_dir to $user_input2.${NC}"
        exit 1
    fi
else
    log_display "Skipped configuring $bitcoin_dir symlink to $user_input2. You will need to specify --datadir $user_input2 when using bitcoin-cli if your data directory is not the default."
fi