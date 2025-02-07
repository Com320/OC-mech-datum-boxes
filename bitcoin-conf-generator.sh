#!/bin/bash

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

# Prompt the user for their inputs
while true; do
    user_input1=$(get_input "Enter location for bitcoin.conf" "/home/bitcoin/bitcoin.conf")
    user_input2=$(get_input "Enter location for data" "/home/bitcoin/data")
    user_input3=$(get_input "Enter value for 'prune'" "550")
    user_input4=$(get_input "Enter value for 'dbcache'" "100")
    user_input5=$(get_input "Enter value for 'rpcauth'" "user:password")

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

# Create or overwrite file.txt with sudo
sudo bash -c "cat > $user_input1/bitcoin.conf" << EOF
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

# Check if the operation was successful
if [ $? -eq 0 ]; then
    echo "File 'bitcoin.conf' has been updated successfully."
else
    echo "An error occurred while updating the file."
    exit 1
fi
