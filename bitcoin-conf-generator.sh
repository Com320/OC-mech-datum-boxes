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

# Prepare default values
default_conf="/etc/bitcoin/bitcoin.conf"
default_data="/var/lib/bitcoind"

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

    confirm_input "Are these values correct?"
    if [ $? -eq 0 ]; then
        break
    fi
    log_display "Let's try again."
    log_display ""
done

# Create directory for the bitcoin.conf file if it doesn't exist
conf_dir=$(dirname "$user_input1")
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
log "  - Config location: $user_input1"
log "  - Data directory: $user_input2"
log "  - Prune value: $user_input3"
log "  - DB Cache: $user_input4"
log "  - RPC Auth: $user_input5"

sudo bash -c "cat > $user_input1" << EOF
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
chown "$username:$username" "$user_input1"

# Set permissions to ensure bitcoind can read the file when run by systemd
# chmod 600 (owner read-write only) is appropriate for config files with credentials
chmod 600 "$user_input1"
log "Set permissions on bitcoin.conf to 600 (owner read-write only)"

# Check if the operation was successful
if [ $? -eq 0 ]; then
    log_display "${GREEN}File 'bitcoin.conf' has been created at $user_input1 successfully.${NC}"
else
    log_display "${RED}An error occurred while creating the file.${NC}"
    exit 1
fi

# Check if default_conf exists
if [ -f "$default_conf" ]; then
    log_display "default_conf file found at $default_conf."
else
    log_display "${RED}Error: default_conf file not found at $default_conf.${NC}"
    exit 1
fi

# Create an alias (symlink) from default_conf to default_data
if ln -sfn "$default_conf" "$default_data"; then
    log_display "Symlink created from $default_conf to $default_data."
else
    log_display "${RED}Error: Failed to create symlink from $default_conf to $default_data.${NC}"
    exit 1
fi


# Get user's home directory
user_home=$(get_home_directory "$username")
bitcoin_dir="$user_home/.bitcoin"

# Display colored warning and info before asking the user
log_display "${YELLOW}You are about to configure the /home/$username user to use bitcoin-cli without specifying the $default_data directory each time.${NC}"
log_display "${RED}IMPORTANT: By choosing yes, it will permanently delete anything in $user_home/.bitcoin. (THIS CANNOT BE UNDONE)${NC}"
log_display "${YELLOW}If this is a new installation, this directory should not contain any critical information.${NC}"

# Ask user for confirmation
read -p "Do you want to proceed? (y/n): " configure_symlink
if [[ "$configure_symlink" == "y" ]]; then
    # Remove the .bitcoin directory if it exists
    if [ -L "$bitcoin_dir" ] || [ -d "$bitcoin_dir" ]; then
        log_display "Removing existing .bitcoin directory or symlink at $bitcoin_dir."
        rm -rf "$bitcoin_dir"
    fi

    # Create symlink for .bitcoin to default_data
    if ln -sfn "$default_data" "$bitcoin_dir"; then
        log_display "${GREEN}Symlink created from $bitcoin_dir to $default_data.${NC}"
    else
        log_display "${RED}Error: Failed to create symlink from $bitcoin_dir to $default_data.${NC}"
        exit 1
    fi
else
    log_display "Skipped configuring $username/.bitcoin symlink to $default_data."
fi