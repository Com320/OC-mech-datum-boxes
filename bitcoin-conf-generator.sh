#!/bin/bash

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging
init_logging "bitcoin-conf-generator"

# Get username from settings.json
username=$(read_json_value "username" "$SETTINGS_FILE")
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
    read -p "$1 (default: $2): " input
    # Log the input for reference
    log "Input for '$1': ${input:-$2} (default was: $2)"
    echo "${input:-$2}"
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
    user_input5=$(get_input "Enter value for 'rpcauth'" "$default_rpcauth")
    user_input6=$(get_input "Enter value for datacarrier 'datacarriersize'" "42")

    echo "You entered the following values:"
    echo "Location for bitcoin.conf: $user_input1"
    echo "Location for data: $user_input2"
    echo "Value for 'prune': $user_input3"
    echo "Value for 'dbcache': $user_input4"
    echo "Value for 'rpcauth': $user_input5"
    echo "Value for 'datacarriersize': $user_input6"

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
datacarriersize=$user_input6
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
