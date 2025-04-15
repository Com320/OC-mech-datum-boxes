#!/bin/bash

# This script generates RPC authentication information using rpcauth.py
# from the Bitcoin Knots source code and saves it to rpcinfo.bin

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging
init_logging "generate-rpcauth"

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

# Find the Bitcoin Knots source directory
btc_src_dir="$user_home/bitcoin/src"
if [ ! -d "$btc_src_dir" ]; then
    log_display "${RED}Bitcoin source directory not found at $btc_src_dir${NC}"
    exit 1
fi

# Path to the rpcauth.py script
rpcauth_script="$btc_src_dir/bitcoin/share/rpcauth/rpcauth.py"
if [ ! -f "$rpcauth_script" ]; then
    log_display "${RED}rpcauth.py script not found at $rpcauth_script${NC}"
    exit 1
fi

# Default RPC username
default_rpc_user="datumuser"

# Ask for RPC username
log_display "${GREEN}Generating RPC authentication details${NC}"
log_display "This will create authentication credentials for Bitcoin RPC access"
read -p "Enter RPC username (default: $default_rpc_user): " rpc_username
rpc_username=${rpc_username:-$default_rpc_user}
log "Using RPC username: $rpc_username"

# Run the rpcauth.py script
log_display "${GREEN}Running rpcauth.py...${NC}"
rpc_output=$(python3 "$rpcauth_script" "$rpc_username")

if [ $? -ne 0 ]; then
    log_display "${RED}Failed to run rpcauth.py${NC}"
    exit 1
fi

# Check if the output contains the expected data
if ! echo "$rpc_output" | grep -q "^rpcauth=" || ! echo "$rpc_output" | grep -q "^Your password:"; then
    log_display "${RED}Failed to generate RPC authentication information. Unexpected output format.${NC}"
    log_display "${RED}Raw output was:${NC}"
    log_display "$rpc_output"
    exit 1
fi

# Save the entire output to rpcinfo.bin
echo "$rpc_output" > "$user_home/rpcinfo.bin"
chown "$username:$username" "$user_home/rpcinfo.bin"
chmod 600 "$user_home/rpcinfo.bin" # Restrictive permissions
log "Saved RPC authentication information to $user_home/rpcinfo.bin"

# Extract the authentication line and password for display only
rpcauth_line=$(echo "$rpc_output" | grep "^rpcauth=" | head -n 1)

# Extract the password - it's on the line after "Your password:"
if grep -q "^Your password:" <<< "$rpc_output"; then
    # Find the line number with "Your password:"
    pwd_line_num=$(grep -n "^Your password:" <<< "$rpc_output" | cut -d':' -f1)
    # Get the next line (actual password)
    if [ -n "$pwd_line_num" ]; then
        next_line=$((pwd_line_num + 1))
        rpc_password=$(sed -n "${next_line}p" <<< "$rpc_output")
        log "Successfully extracted RPC password from output"
    fi
fi

# Display the auth info for user reference
log_display "${GREEN}RPC authentication details generated and saved to $user_home/rpcinfo.bin${NC}"
log_display "${GREEN}These credentials will be used by both Bitcoin and DATUM config generators${NC}"
log_display ""
log_display "RPC Auth Line: ${GREEN}$rpcauth_line${NC}"
log_display "RPC Username: ${GREEN}$rpc_username${NC}"
if [ -n "$rpc_password" ]; then
    log_display "RPC Password: ${GREEN}$rpc_password${NC}"
else
    log_display "${RED}Could not extract password from output.${NC}"
fi
log_display ""
log_display "${RED}IMPORTANT: Save this information!${NC}"

exit 0