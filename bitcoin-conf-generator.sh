#!/bin/bash

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Global Variables & Settings
SETTINGS_FILE="$(dirname "$0")/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo -e "${RED}Settings file not found at $SETTINGS_FILE${NC}"
    exit 1
fi

# Get username from settings.json
username=$(grep -o '"username": *"[^"]*"' "$SETTINGS_FILE" | cut -d'"' -f4)
if [ -z "$username" ]; then
    echo -e "${RED}Could not determine username from settings.json.${NC}"
    username="bitcoin"  # Default username
fi

# Get user's home directory
user_home=$(eval echo ~"$username")
if [ ! -d "$user_home" ]; then
    echo -e "${RED}User home directory for $username not found.${NC}"
    exit 1
fi

# Check for RPC info file
rpcinfo_file="$user_home/rpcinfo.bin"
if [ -f "$rpcinfo_file" ]; then
    echo -e "${GREEN}Found RPC authentication info:${NC}"
    # Extract the line that starts with "rpcauth="
    rpcauth_line=$(grep "^rpcauth=" "$rpcinfo_file")
    if [ -n "$rpcauth_line" ]; then
        # Extract just the value after "rpcauth="
        rpcauth_value=$(echo "$rpcauth_line" | cut -d'=' -f2)
        echo -e "${GREEN}$rpcauth_line${NC}"
        default_rpcauth="$rpcauth_value"
    else
        echo -e "${RED}Could not find rpcauth line in $rpcinfo_file${NC}"
        default_rpcauth="username:salt$hash"
    fi
else
    echo -e "${RED}RPC authentication info not found. Run generate-rpcauth.sh first.${NC}"
    default_rpcauth="username:salt$hash"
fi

# Function to get user input with default value
get_input() {
    read -p "$1 (default: $2): " input
    echo "${input:-$2}"
}

# Function to confirm user input
confirm_input() {
    echo "$1"
    read -p "Is this correct? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        return 1
    fi
    return 0
}

# Prepare default values
default_conf="/etc/bitcoin/bitcoin.conf"
default_data="/var/lib/bitcoind"

# Show current user being used
echo -e "Using configuration for user: ${GREEN}$username${NC}"
echo -e "Home directory: ${GREEN}$user_home${NC}"
echo -e "Using system locations by default for improved compatibility with systemd services"

# Prompt the user for their inputs
while true; do
    user_input1=$(get_input "Enter location for bitcoin.conf" "$default_conf")
    user_input2=$(get_input "Enter location for data" "$default_data")
    user_input3=$(get_input "Enter value for 'prune'" "550")
    user_input4=$(get_input "Enter value for 'dbcache'" "100")
    user_input5=$(get_input "Enter value for 'rpcauth'" "$default_rpcauth")

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
    echo "Let's try again."
    echo
done

# Create directory for the bitcoin.conf file if it doesn't exist
conf_dir=$(dirname "$user_input1")
if [ ! -d "$conf_dir" ]; then
    sudo mkdir -p "$conf_dir"
    if [[ "$conf_dir" == "/etc/bitcoin" ]]; then
        # System directory should be root:username with stricter permissions
        sudo chown -R root:"$username" "$conf_dir"
        sudo chmod 750 "$conf_dir"
    else
        # User directory with standard permissions
        sudo chown -R "$username:$username" "$conf_dir"
        sudo chmod 700 "$conf_dir"
    fi
fi

# Create the data directory if it doesn't exist
if [ ! -d "$user_input2" ]; then
    sudo mkdir -p "$user_input2"
    if [[ "$user_input2" == "/var/lib/bitcoind" ]]; then
        # System data directory should be username:username
        sudo chown -R "$username:$username" "$user_input2"
        sudo chmod 750 "$user_input2"
    else
        # User data directory
        sudo chown -R "$username:$username" "$user_input2"
        sudo chmod 700 "$user_input2"
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
EOF

# Set ownership
chown "$username:$username" "$user_input1"

# Set permissions to ensure bitcoind can read the file when run by systemd
# chmod 600 (owner read-write only) is appropriate for config files with credentials
chmod 600 "$user_input1"
echo "Set permissions on bitcoin.conf to 600 (owner read-write only)"

# Check if the operation was successful
if [ $? -eq 0 ]; then
    echo -e "${GREEN}File 'bitcoin.conf' has been created at $user_input1 successfully.${NC}"
else
    echo -e "${RED}An error occurred while creating the file.${NC}"
    exit 1
fi
