#!/bin/bash
# troubleshoot-bitcoin-conf.sh - Script to diagnose and fix Bitcoin configuration permissions

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Source shared utility functions
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging for this script
init_logging "troubleshoot_bitcoin_conf"

log "Starting Bitcoin configuration troubleshooting..."

# Get username using the shared function
username=$(get_username)
if [ $? -ne 0 ]; then
    log_display "${RED}Failed to get valid username. Exiting.${NC}"
    exit 1
fi

# Get user's home directory using the shared function
user_home=$(get_home_directory "$username")
if [ $? -ne 0 ]; then
    log_display "${RED}Failed to get home directory. Exiting.${NC}"
    exit 1
fi

log "Using home directory: $user_home"

# Check Bitcoin configuration
conf_path="$user_home/.bitcoin/bitcoin.conf"
conf_dir="$user_home/.bitcoin"
data_dir="$user_home/.bitcoin/data"

# Display current permissions and ownership
log_display "${GREEN}===== Current Bitcoin Configuration Status =====${NC}"
log_display "Bitcoin configuration path: $conf_path"

if [ -f "$conf_path" ]; then
    log_display "${GREEN}Config file exists.${NC}"
    log_display "Config file permissions:"
    ls -la "$conf_path"
else
    log_display "${RED}Config file not found!${NC}"
fi

log_display "\nDirectory permissions:"
ls -la "$conf_dir"

log_display "\nTesting accessibility:"
log_display "1. Direct access test as root:"
cat "$conf_path" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    log_display "${GREEN}Root can read the file.${NC}"
else
    log_display "${RED}Root cannot read the file!${NC}"
fi

log_display "\n2. Direct access test as $username:"
sudo -u "$username" cat "$conf_path" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    log_display "${GREEN}$username can read the file.${NC}"
else
    log_display "${RED}$username cannot read the file!${NC}"
fi

# Check for AppArmor
log_display "\n${GREEN}===== Security Context =====${NC}"
if command -v aa-status &> /dev/null; then
    log_display "AppArmor status:"
    aa-status | grep -i bitcoin
fi

# Check for SELinux
if command -v getenforce &> /dev/null; then
    selinux_status=$(getenforce)
    log_display "SELinux status: $selinux_status"
    
    if [ "$selinux_status" != "Disabled" ]; then
        log_display "SELinux context for config file:"
        ls -Z "$conf_path" 2>/dev/null
    fi
fi

# Path traversal check
log_display "\n${GREEN}===== Path Traversal Permissions =====${NC}"
current_path="$conf_dir"
while [ "$current_path" != "/" ]; do
    log_display "Permissions for $current_path:"
    ls -ld "$current_path"
    current_path=$(dirname "$current_path")
done

# Check for common issues
log_display "\n${GREEN}===== Identifying Common Issues =====${NC}"

# Check home directory permissions
home_perms=$(stat -c "%a" "$user_home")
if [[ "$home_perms" != "755" && "$home_perms" != "750" && "$home_perms" != "700" ]]; then
    log_display "${YELLOW}Home directory has unusual permissions: $home_perms${NC}"
fi

# Check that the service is actually using the bitcoin user
log_display "\n${GREEN}===== Service Configuration =====${NC}"
if [ -f "/etc/systemd/system/bitcoin_knots.service" ]; then
    service_user=$(grep "^User=" "/etc/systemd/system/bitcoin_knots.service" | cut -d'=' -f2)
    log_display "Service configured to run as user: $service_user"
    
    if [ "$service_user" != "$username" ]; then
        log_display "${RED}WARNING: Service user ($service_user) doesn't match expected user ($username)!${NC}"
    fi
else
    log_display "${RED}Bitcoin service file not found!${NC}"
fi

# Offer to fix the issues
log_display "\n${GREEN}===== Fix Options =====${NC}"
log_display "1. Recreate .bitcoin directory with proper permissions"
log_display "2. Copy config to /etc/bitcoin and update service"
log_display "3. Fix permissions of existing files"
log_display "4. Exit without changes"

read -p "Choose an option (1-4): " fix_option

case $fix_option in
    1)
        # Option 1: Recreate directory structure
        log_display "Recreating .bitcoin directory with proper permissions..."
        
        # Backup existing config if it exists
        if [ -f "$conf_path" ]; then
            sudo cp "$conf_path" "/tmp/bitcoin.conf.bak"
            log_display "Config backed up to /tmp/bitcoin.conf.bak"
        fi
        
        # Recreate directory with proper permissions
        sudo rm -rf "$conf_dir"
        sudo mkdir -p "$conf_dir"
        sudo mkdir -p "$data_dir"
        sudo chown -R "$username:$username" "$conf_dir"
        sudo chmod -R 700 "$conf_dir"
        
        # Restore config if backup exists
        if [ -f "/tmp/bitcoin.conf.bak" ]; then
            sudo cp "/tmp/bitcoin.conf.bak" "$conf_path"
            sudo chown "$username:$username" "$conf_path"
            sudo chmod 600 "$conf_path"
            log_display "Config restored from backup."
        else
            # Create minimal config
            sudo bash -c "cat > $conf_path" << EOF
datadir=$data_dir
server=1
rpcallowip=127.0.0.1
rpcuser=bitcoin
rpcpassword=bitcoin
EOF
            sudo chown "$username:$username" "$conf_path"
            sudo chmod 600 "$conf_path"
            log_display "Created new minimal config file."
        fi
        
        log_display "${GREEN}Directory and permissions reset complete.${NC}"
        ;;
    
    2)
        # Option 2: Move to system location
        log_display "Setting up config in /etc/bitcoin..."
        
        # Create system directory
        sudo mkdir -p "/etc/bitcoin"
        sudo mkdir -p "/var/lib/bitcoind"
        
        # Copy config
        if [ -f "$conf_path" ]; then
            sudo cp "$conf_path" "/etc/bitcoin/bitcoin.conf"
        else
            # Create minimal config
            sudo bash -c "cat > /etc/bitcoin/bitcoin.conf" << EOF
datadir=/var/lib/bitcoind
server=1
rpcallowip=127.0.0.1
rpcuser=bitcoin
rpcpassword=bitcoin
EOF
        fi
        
        # Update datadir in config to use /var/lib/bitcoind instead of $data_dir
        sudo sed -i "s|datadir=.*|datadir=/var/lib/bitcoind|" "/etc/bitcoin/bitcoin.conf"
        
        # Copy existing data if needed
        if [ -d "$data_dir" ] && [ "$(ls -A "$data_dir" 2>/dev/null)" ]; then
            log_display "Copying existing blockchain data to /var/lib/bitcoind (this may take a while)..."
            sudo cp -r "$data_dir"/* "/var/lib/bitcoind/" 2>/dev/null || true
        fi
        
        # Set permissions
        sudo chown -R root:$username "/etc/bitcoin"
        sudo chmod 750 "/etc/bitcoin"
        sudo chmod 640 "/etc/bitcoin/bitcoin.conf"
        
        # Set permissions for data directory
        sudo chown -R "$username:$username" "/var/lib/bitcoind"
        sudo chmod -R 750 "/var/lib/bitcoind"
        
        # Update service to use this config
        if [ -f "/etc/systemd/system/bitcoin_knots.service" ]; then
            log_display "Updating service to use system config location..."
            sudo sed -i "s|^ExecStart=.*|ExecStart=/usr/local/bin/bitcoind -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoind|" "/etc/systemd/system/bitcoin_knots.service"
            sudo systemctl daemon-reload
        fi
        
        log_display "${GREEN}System config setup complete.${NC}"
        ;;
    
    3)
        # Option 3: Fix permissions of existing files
        log_display "Fixing permissions of existing files..."
        
        # Ensure home directory has correct permissions
        sudo chmod 750 "$user_home"
        
        # Fix .bitcoin directory permissions
        sudo chown -R "$username:$username" "$conf_dir"
        sudo chmod -R 700 "$conf_dir"
        
        # Fix config file permissions specifically
        if [ -f "$conf_path" ]; then
            sudo chown "$username:$username" "$conf_path"
            sudo chmod 600 "$conf_path"
        fi
        
        log_display "${GREEN}Permissions fixed.${NC}"
        ;;
    
    4)
        log_display "Exiting without changes."
        ;;
    
    *)
        log_display "${RED}Invalid option. Exiting.${NC}"
        ;;
esac

# Try to restart the service if it exists
if [ -f "/etc/systemd/system/bitcoin_knots.service" ] && [ "$fix_option" != "4" ]; then
    log_display "\n${GREEN}===== Restarting Service =====${NC}"
    log_display "Attempting to restart Bitcoin service..."
    sudo systemctl daemon-reload
    sudo systemctl restart bitcoin_knots.service
    sleep 3
    
    # Check if service started successfully
    systemctl is-active --quiet bitcoin_knots.service
    if [ $? -eq 0 ]; then
        log_display "${GREEN}Service started successfully!${NC}"
    else
        log_display "${RED}Service failed to start. Current status:${NC}"
        systemctl status bitcoin_knots.service
    fi
fi

log "Bitcoin configuration troubleshooting completed."