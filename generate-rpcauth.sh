#!/bin/bash

# This script generates RPC authentication information using rpcauth.py
# from the Bitcoin Knots source code and saves it to rpcinfo.bin

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

# Find the Bitcoin Knots source directory
btc_src_dir="$user_home/bitcoin/src"
if [ ! -d "$btc_src_dir" ]; then
    echo -e "${RED}Bitcoin source directory not found at $btc_src_dir${NC}"
    exit 1
fi

# Path to the rpcauth.py script
rpcauth_script="$btc_src_dir/bitcoin/share/rpcauth/rpcauth.py"
if [ ! -f "$rpcauth_script" ]; then
    echo -e "${RED}rpcauth.py script not found at $rpcauth_script${NC}"
    exit 1
fi

# Default RPC username
default_rpc_user="datumuser"

# Ask for RPC username
echo -e "${GREEN}Generating RPC authentication details${NC}"
echo -e "This will create authentication credentials for Bitcoin RPC access"
read -p "Enter RPC username (default: $default_rpc_user): " rpc_username
rpc_username=${rpc_username:-$default_rpc_user}

# Run the rpcauth.py script
echo -e "${GREEN}Running rpcauth.py...${NC}"
rpc_output=$(python3 "$rpcauth_script" "$rpc_username")

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to run rpcauth.py${NC}"
    exit 1
fi

# Check if the output contains the expected data
if ! echo "$rpc_output" | grep -q "^rpcauth=" || ! echo "$rpc_output" | grep -q "^Your password:"; then
    echo -e "${RED}Failed to generate RPC authentication information. Unexpected output format.${NC}"
    echo -e "${RED}Raw output was:${NC}"
    echo "$rpc_output"
    exit 1
fi

# Save the entire output to rpcinfo.bin
echo "$rpc_output" > "$user_home/rpcinfo.bin"
chown "$username:$username" "$user_home/rpcinfo.bin"
chmod 600 "$user_home/rpcinfo.bin" # Restrictive permissions

# Extract the authentication line and password for display only
rpcauth_line=$(echo "$rpc_output" | grep "^rpcauth=" | head -n 1)
rpc_password=$(echo "$rpc_output" | grep "^Your password:" | sed 's/Your password://' | tr -d '[:space:]')

echo -e "${GREEN}RPC authentication details generated and saved to $user_home/rpcinfo.bin${NC}"
echo -e "${GREEN}These credentials will be used by both Bitcoin and DATUM config generators${NC}"
echo
echo -e "RPC Auth Line: ${GREEN}$rpcauth_line${NC}"
echo -e "RPC Username: ${GREEN}$rpc_username${NC}"
echo -e "RPC Password: ${GREEN}$rpc_password${NC}"
echo
echo -e "${RED}IMPORTANT: Save this information!${NC}"

exit 0