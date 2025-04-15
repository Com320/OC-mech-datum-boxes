#!/bin/bash

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging
init_logging "datum-config-generator"

# Get username from settings.json
username=$(read_json_value "username" "$SETTINGS_FILE")
if [ -z "$username" ]; then
    log_display "${RED}Could not determine username from settings.json.${NC}"
    username="bitcoin"  # Default username
    log "Using default username: $username"
fi

# Get coinbase tag settings from settings.json (with defaults if not found)
coinbase_tag_primary=$(read_json_value "coinbase_tag_primary" "$SETTINGS_FILE")
if [ -z "$coinbase_tag_primary" ]; then
    log_display "${YELLOW}Could not determine coinbase_tag_primary from settings.json. Using default 'DATUM'.${NC}"
    coinbase_tag_primary="DATUM"  # Default value
    log "Using default coinbase_tag_primary: $coinbase_tag_primary"
fi

coinbase_tag_secondary=$(read_json_value "coinbase_tag_secondary" "$SETTINGS_FILE")
if [ -z "$coinbase_tag_secondary" ]; then
    coinbase_tag_secondary=""  # Default empty secondary tag
    log "Using empty coinbase_tag_secondary"
fi

# Get user's home directory
user_home=$(eval echo ~"$username")
if [ ! -d "$user_home" ]; then
    log_display "${RED}User home directory for $username not found.${NC}"
    exit 1
fi

# Check for RPC information
rpcinfo_file="$user_home/rpcinfo.bin"
default_rpc_user="datumuser"
default_rpc_password=""

# Extract RPC username and password from rpcinfo.bin
if [ -f "$rpcinfo_file" ]; then
    log_display "${GREEN}Found RPC authentication info:${NC}"
    
    # Extract the username from rpcauth line (format is rpcauth=username:hash)
    rpcauth_line=$(grep "^rpcauth=" "$rpcinfo_file" | head -n 1)
    default_rpc_user=$(echo "$rpcauth_line" | cut -d'=' -f2 | cut -d':' -f1)
    
    # Extract the password - it's on the line after "Your password:"
    if grep -q "^Your password:" "$rpcinfo_file"; then
        # Find the line number with "Your password:"
        pwd_line_num=$(grep -n "^Your password:" "$rpcinfo_file" | cut -d':' -f1)
        # Get the next line (actual password)
        if [ -n "$pwd_line_num" ]; then
            next_line=$((pwd_line_num + 1))
            default_rpc_password=$(sed -n "${next_line}p" "$rpcinfo_file")
            
            # Display clear RPC credential information at the top
            log_display "${YELLOW}=========== RPC CREDENTIALS ===========${NC}"
            log_display "RPC Username: ${GREEN}$default_rpc_user${NC}"
            log_display "RPC Password: ${GREEN}$default_rpc_password${NC}"
            log_display "${YELLOW}=======================================${NC}"
            log_display ""
        else
            log_display "${RED}Could not extract password line number from rpcinfo.bin${NC}"
        fi
    else
        log_display "${RED}Could not find 'Your password:' line in rpcinfo.bin${NC}"
    fi
else
    log_display "${RED}RPC authentication info not found. Run generate-rpcauth.sh first.${NC}"
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

# Show current user being used
log_display "Using configuration for user: ${GREEN}$username${NC}"
log_display "Home directory: ${GREEN}$user_home${NC}"

# Default config path
default_config_path="$user_home/datum"
default_log_file="$default_config_path/logs/datum.log"

# Ask for config path with the appropriate default
while true; do
    log_display "Where do you want to store datum_gateway_config.json?"
    read -p "Enter path (default: $default_config_path): " config_path
    config_path=${config_path:-$default_config_path}
    filename="$config_path/datum_gateway_config.json"
    log "Selected config path: $config_path"

    # Create JSON content with user inputs or defaults
    json_content=$(cat <<EOF
{
  "bitcoind": {
    "rpcurl": "$(get_input "Enter bitcoind rpcurl" "localhost:28332")",
    "rpcuser": "$(get_input "Enter bitcoind rpcuser" "$default_rpc_user")",
    "rpcpassword": "$(get_input "Enter bitcoind rpcpassword" "$default_rpc_password")",
    "work_update_seconds": $(get_input "Enter work_update_seconds" 40)
  },
  "stratum": {
    "listen_port": $(get_input "Enter stratum listen_port" 23334),
    "max_clients_per_thread": $(get_input "Enter max_clients_per_thread" 2000),
    "max_threads": $(get_input "Enter max_threads" 10),
    "max_clients": $(get_input "Enter max_clients" 20000),
    "vardiff_min": $(get_input "Enter vardiff_min" 16384)
  },
  "mining": {
    "pool_address": "$(get_input "Enter pool_address" "")",
    "coinbase_tag_primary": "$(get_input "Enter coinbase_tag_primary" "$coinbase_tag_primary")",
    "coinbase_tag_secondary": "$(get_input "Enter coinbase_tag_secondary" "$coinbase_tag_secondary")"
  },
  "api": {
    "listen_port": $(get_input "Enter API listen_port" 7152),
    "admin_password": "$(get_input "Enter API admin password" "admin")",
    "modify_conf": $(get_input "Allow API to modify config? (true/false)" false)
  },
  "logger": {
    "log_to_file": $(get_input "Log to file? (true/false)" true),
    "log_file": "$(get_input "Enter log file path" "$default_log_file")",
    "log_level_file": $(get_input "Enter log level (0-3)" 0)
  },
  "datum": {
    "pool_host": "$(get_input "Enter pool host" "datum-beta1.mine.ocean.xyz")",
    "pool_port": $(get_input "Enter pool port" 28915),
    "pool_pass_workers": $(get_input "Pass workers to pool? (true/false)" true),
    "pool_pass_full_users": $(get_input "Pass stratum miner usernames as raw usernames to the pool? (true/false)" true),
    "pooled_mining_only": $(get_input "Pooled mining only? (true/false)" true)
  }
}
EOF
)    # Show preview of the configuration
    log_display "${GREEN}Configuration preview:${NC}"
    log_display "$json_content"
    
    # Ask for confirmation
    confirm_input "Is this configuration correct?"
    if [ $? -eq 0 ]; then
        break
    fi
    log_display "Let's try again."
    log_display ""
done

# Create directory for the config file if it doesn't exist
if [ ! -d "$config_path" ]; then
    mkdir -p "$config_path"
    if [ $? -ne 0 ]; then
        log_display "${RED}Failed to create directory $config_path${NC}"
        exit 1
    fi
    chown -R "$username:$username" "$config_path"
    log "Created directory $config_path"
fi

# Create logs directory if it doesn't exist
log_dir=$(dirname "$default_log_file")
if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir"
    if [ $? -ne 0 ]; then
        log_display "${RED}Failed to create directory $log_dir${NC}"
        exit 1
    fi
    chown -R "$username:$username" "$log_dir"
    log "Created logs directory $log_dir"
fi

# Write the JSON content to the file
echo "$json_content" | sudo tee "$filename" > /dev/null

# Set proper ownership
chown "$username:$username" "$filename"
log "Created configuration file: $filename"

# Check if file was created successfully
if [ $? -eq 0 ]; then
    log_display "${GREEN}File '$filename' created successfully.${NC}"
    
    # Remind user of the RPC credentials after configuration is created
    if [ -n "$default_rpc_password" ]; then
        log_display ""
        log_display "${YELLOW}=========== RPC CREDENTIALS ===========${NC}"
        log_display "RPC Username: ${GREEN}$default_rpc_user${NC}"
        log_display "RPC Password: ${GREEN}$default_rpc_password${NC}"
        log_display "${YELLOW}=======================================${NC}"
    fi
else
    log_display "${RED}An error occurred while creating the file.${NC}"
    exit 1
fi
