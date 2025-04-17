#!/bin/bash

# Define a cleanup function to handle interrupts
cleanup() {
    log_display "${YELLOW}Script interrupted by user. Bitcoin service setup is complete.${NC}"
    log_display "${YELLOW}Note: Bitcoin is syncing the blockchain in the background.${NC}"
    log_display "${YELLOW}This process may take hours or days to complete.${NC}"
    log_display "${GREEN}To check sync status: ${NC}sudo journalctl -u bitcoin_knots.service -f"
    exit 0
}

# Set up the trap for interrupt signals
trap cleanup INT

# Source shared utility functions
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging for this script
init_logging "generate_bitcoin_service"

log "Starting Bitcoin service generation script..."

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

# Use the directly installed binary
BITCOIN_BINARY="/usr/local/bin/bitcoind"

# Verify the binary exists and is executable
log "Verifying Bitcoin binary at $BITCOIN_BINARY..."

if [ -f "$BITCOIN_BINARY" ]; then
    log "Found binary at $BITCOIN_BINARY"
    
    # Verify binary permissions and fix if needed
    log "Checking binary permissions"
    binary_permissions=$(stat -c "%a %U:%G" "$BITCOIN_BINARY" 2>/dev/null)
    log "Binary permissions: $binary_permissions"
    
    # Ensure the binary is executable by all users
    sudo chmod 755 "$BITCOIN_BINARY"
    log "Updated binary permissions to 755"
else
    log_display "${RED}Error: Bitcoin binary not found at $BITCOIN_BINARY${NC}"
    log_display "${RED}Please ensure the build process completed successfully.${NC}"
    exit 1
fi

# Check that the binary is actually executable by attempting to run it
log "Testing binary execution..."
if ! "$BITCOIN_BINARY" --version > /dev/null 2>&1; then
    log_display "${RED}Error: Binary exists but cannot be executed.${NC}"
    log "Binary details:"
    file "$BITCOIN_BINARY" >> "$LOG_FILE" 2>&1
    ldd "$BITCOIN_BINARY" >> "$LOG_FILE" 2>&1
    exit 1
else
    log "Binary execution test passed"
    # Check if service user can execute it
    if su - "$username" -c "$BITCOIN_BINARY --version > /dev/null 2>&1"; then
        log "Service user $username can execute binary"
    else
        log_display "${RED}Warning: Service user $username cannot execute binary!${NC}"
        log_display "${YELLOW}This may cause problems when running as a service.${NC}"
    fi
fi

log "Using Bitcoin binary path: $BITCOIN_BINARY"

# Path to the template service file in the cloned Bitcoin Knots repository
TEMPLATE_PATH="$user_home/bitcoin/src/bitcoin/contrib/init/bitcoind.service"
log "Looking for template service file at: $TEMPLATE_PATH"

# Check if the template file exists
if [ ! -f "$TEMPLATE_PATH" ]; then
    log "${RED}WARNING: Bitcoin service template file not found at $TEMPLATE_PATH${NC}"
    log "${RED}WARNING: Using fallback service definition which lacks recommended security hardening!${NC}"
    log "${RED}WARNING: This is NOT recommended for production deployments!${NC}"
    log "${YELLOW}If you want the full hardened service definition, make sure Bitcoin Knots source code is properly cloned.${NC}"
    
    echo -e "${RED}WARNING: Bitcoin service template file not found at $TEMPLATE_PATH${NC}"
    echo -e "${RED}WARNING: Using fallback service definition which lacks recommended security hardening!${NC}"
    echo -e "${RED}WARNING: This is NOT recommended for production deployments!${NC}"
    echo ""
    echo -e "${YELLOW}If you want the full hardened service definition, make sure Bitcoin Knots source code is properly cloned.${NC}"
    echo "Press Ctrl+C now to abort, or wait 10 seconds to continue with fallback..."
    sleep 10
    log "Continuing with fallback service definition..."
    echo "Continuing with fallback service definition..."
    
    # Write the content to the service file with sudo (using fallback simple template)
    log "Creating fallback service file at /etc/systemd/system/bitcoin_knots.service"
    sudo bash -c "cat > /etc/systemd/system/bitcoin_knots.service" << EOF
[Unit]
Description=Bitcoin Knots Service
After=network.target

[Service]
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/bitcoind
Restart=always
User=$username
Group=$username
RuntimeDirectory=bitcoind
RuntimeDirectoryMode=0710

# Security hardening
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_NET_RAW
NoNewPrivileges=yes
RemoveIPC=yes
PrivateDevices=yes
ProtectClock=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
PrivateMounts=yes
SystemCallArchitectures=native
MemoryDenyWriteExecute=yes
RestrictNamespaces=net pid
ProtectHostname=yes
LockPersonality=yes
ProtectKernelTunables=yes
RestrictRealtime=yes
ProtectSystem=full
ProtectProc=invisible
ProcSubset=pid
ProtectHome=tmpfs
BindPaths=/home/$username/
PrivateTmp=yes
PrivateUsers=yes
SystemCallFilter=~@clock @cpu-emulation @debug @module @mount @obsolete @privileged @raw-io @reboot @swap

[Install]
WantedBy=multi-user.target
EOF
    log "Fallback service file created"
else
    log_display "${GREEN}Found Bitcoin Knots service template at: $TEMPLATE_PATH${NC}"
    
    # Create a temporary modified version of the template
    TMP_SERVICE_FILE="/tmp/bitcoin_knots.service.tmp"
    log "Creating temporary service file at $TMP_SERVICE_FILE"
    
    # Copy the template and perform modifications
    cp "$TEMPLATE_PATH" "$TMP_SERVICE_FILE"
    
    # Update the service file with our customizations
    log "Updating service file with custom settings"
    
    # Replace User and Group entries with our username
    log "Setting User and Group to $username"
    sed -i "s|^User=.*|User=$username|" "$TMP_SERVICE_FILE"
    sed -i "s|^Group=.*|Group=$username|" "$TMP_SERVICE_FILE"
    
    # Simplify the ExecStart line to only use the binary path without arguments
    # This ensures ALL arguments are completely removed
    log "Setting ExecStart path to use /usr/local/bin/bitcoind with system paths"
    sed -i "s|^ExecStart=.*|ExecStart=/usr/local/bin/bitcoind -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoind|g" "$TMP_SERVICE_FILE"
    
    # Remove any multi-line ExecStart continuation lines if they exist
    sed -i '/^[[:space:]]*-/d' "$TMP_SERVICE_FILE"
    
    # Add PATH environment if it doesn't exist
    if ! grep -q "^Environment=PATH=" "$TMP_SERVICE_FILE"; then
        log "Adding PATH environment to service file"
        sed -i '/\[Service\]/a Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$TMP_SERVICE_FILE"
    fi
    
    # Ensure proper RuntimeDirectory settings
    if ! grep -q "^RuntimeDirectory=" "$TMP_SERVICE_FILE"; then
        log "Adding RuntimeDirectory to service file"
        sed -i '/\[Service\]/a RuntimeDirectory=bitcoind\nRuntimeDirectoryMode=0710' "$TMP_SERVICE_FILE"
    fi
    
    # Keep important security hardening features from the template
    # but replace paths to match our setup (mainly under StateDirectory & ConfigurationDirectory)
    log "Updating configuration paths while preserving security features"
    
    # Replace state directory path if it exists
    if grep -q "^StateDirectory=" "$TMP_SERVICE_FILE"; then
        log "Removing StateDirectory as we're using user's home directory for data"
        sed -i '/^StateDirectory=/d' "$TMP_SERVICE_FILE"
    fi
    
    # Replace configuration directory path if it exists
    if grep -q "^ConfigurationDirectory=" "$TMP_SERVICE_FILE"; then
        log "Removing ConfigurationDirectory as we're using user's home directory for config"
        sed -i '/^ConfigurationDirectory=/d' "$TMP_SERVICE_FILE"
    fi
    
    # Modify/remove path-specific permissions that may cause issues
    if grep -q "^ExecStartPre=/bin/chgrp bitcoin /etc/bitcoin" "$TMP_SERVICE_FILE"; then
        log "Removing ExecStartPre that modifies /etc/bitcoin"
        sed -i '/^ExecStartPre=\/bin\/chgrp/d' "$TMP_SERVICE_FILE"
    fi
    
    # Display the changes for verification
    log "Modified service file content (excerpt):"
    grep "^ExecStart=" "$TMP_SERVICE_FILE" | tee -a "$LOG_FILE"
    
    # Copy the final service file to systemd directory
    log "Copying service file to /etc/systemd/system/bitcoin_knots.service"
    sudo cp "$TMP_SERVICE_FILE" "/etc/systemd/system/bitcoin_knots.service"
    sudo chmod 644 "/etc/systemd/system/bitcoin_knots.service"
    rm "$TMP_SERVICE_FILE"
    log "Service file successfully copied and permissions set"
fi

# Check if the operation was successful
if [ $? -eq 0 ]; then
    log_display "${GREEN}File 'bitcoin_knots.service' has been created and user inserted correctly.${NC}"
    log "Service configuration saved to: /etc/systemd/system/bitcoin_knots.service"
    echo "Service configuration saved to: /etc/systemd/system/bitcoin_knots.service"
    
    # Enable and start the service if requested
    read -p "Do you want to enable and start the service now? (y/n): " start_service
    if [[ "$start_service" == "y" ]]; then
        log "User chose to enable and start the service"
        log "Running: systemctl daemon-reload"
        sudo systemctl daemon-reload
        log "Running: systemctl enable bitcoin_knots.service"
        sudo systemctl enable bitcoin_knots.service
        
        log_display "${YELLOW}Starting Bitcoin service in the background...${NC}"
        log "Running: systemctl start bitcoin_knots.service"
        
        # Start the service in the background to prevent hanging
        sudo systemctl start bitcoin_knots.service &
        
        # Wait a brief moment for the service to register
        sleep 1
        
        # Don't use status command which can hang - just print completion message
        log_display "${GREEN}Service has been enabled and started.${NC}"
        
        # Important information about blockchain sync
        log_display ""
        log_display "${YELLOW}Important: Bitcoin will now synchronize the blockchain in the background.${NC}"
        log_display "${YELLOW}This process may take hours or days depending on your hardware and internet connection.${NC}"
        log_display "${GREEN}You can proceed with the rest of the installation while synchronization continues.${NC}"
        log_display "${YELLOW}To check sync status later: ${GREEN}sudo journalctl -u bitcoin_knots.service -f${NC}"
        log_display ""
    else
        log "User chose not to enable and start the service"
        echo "You can manually start the service with: sudo systemctl start bitcoin_knots.service"
    fi
else
    log_display "${RED}An error occurred while creating or editing the service file.${NC}"
    exit 1
fi

# If the service failed to start, offer to show the logs
if [ $? -ne 0 ]; then
    log_display "${RED}Service failed to start. Checking logs...${NC}"
    echo "Last 20 lines from journalctl:"
    sudo journalctl -u bitcoin_knots.service -n 20 --no-pager | tee -a "$LOG_FILE"
    
    log_display "${YELLOW}Trying to debug the issue...${NC}"
    log_display "Testing binary execution directly:"
    sudo -u "$username" "$BITCOIN_BINARY" -? | head -n 5 | tee -a "$LOG_FILE"
    
    log_display "${YELLOW}Checking bitcoin.conf permissions and accessibility:${NC}"
    # Check bitcoin.conf permissions in system location
    conf_path="/etc/bitcoin/bitcoin.conf"
    log_display "Bitcoin config path: $conf_path"
    ls -la "$conf_path" 2>&1 | tee -a "$LOG_FILE"
    
    # Check parent directory permissions
    log_display "Parent directory permissions:"
    ls -la "/etc/bitcoin/" 2>&1 | tee -a "$LOG_FILE"
    
    # Check data directory permissions
    log_display "Data directory permissions:"
    ls -la "/var/lib/bitcoind" 2>&1 | tee -a "$LOG_FILE"
    
    # Check if SELinux is enabled
    if command -v getenforce &> /dev/null; then
        selinux_status=$(getenforce)
        log_display "SELinux status: $selinux_status"
        
        if [ "$selinux_status" != "Disabled" ]; then
            log_display "${YELLOW}SELinux is enabled. Checking context:${NC}"
            ls -Z "$conf_path" 2>&1 | tee -a "$LOG_FILE"
            
            log_display "${YELLOW}Attempting to fix SELinux context:${NC}"
            sudo chcon -t bitcoin_exec_t "$BITCOIN_BINARY" 2>&1 | tee -a "$LOG_FILE"
            sudo chcon -t user_home_t "$conf_path" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    
    # Check for AppArmor
    if command -v aa-status &> /dev/null; then
        log_display "AppArmor status:"
        sudo aa-status | grep -i bitcoin | tee -a "$LOG_FILE"
    fi
    
    # Test if bitcoin user can directly read the file
    log_display "Testing if bitcoin user can read the config file directly:"
    sudo -u "$username" cat "$conf_path" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_display "${GREEN}Bitcoin user can read the config file.${NC}"
    else
        log_display "${RED}Bitcoin user cannot read the config file!${NC}"
        
        # Try an alternative approach - copy config to temp location with proper permissions
        log_display "${YELLOW}Attempting alternative approach - creating a copy of the config file:${NC}"
        tmp_conf="/tmp/bitcoin.conf"
        sudo cp "$conf_path" "$tmp_conf"
        sudo chown "$username:$username" "$tmp_conf"
        sudo chmod 600 "$tmp_conf"
        
        # Test direct execution with the temp config
        log_display "Testing bitcoind with temp config file:"
        sudo -u "$username" "$BITCOIN_BINARY" -conf="$tmp_conf" -daemon=0 -printtoconsole=0 -rpcpassword=test -rpcuser=test -server=0 -listenonion=0 -noonion=1 -proxy= -listen=0 -disablewallet=1 2>&1 | head -n 10 | tee -a "$LOG_FILE"
        
        log_display "${YELLOW}Consider recreating the .bitcoin directory with proper permissions:${NC}"
        log_display "sudo mkdir -p /home/bitcoin/.bitcoin/data"
        log_display "sudo chown -R bitcoin:bitcoin /home/bitcoin/.bitcoin"
        log_display "sudo chmod -R 700 /home/bitcoin/.bitcoin"
    fi
    
    log_display "${YELLOW}Checking binary library dependencies:${NC}"
    ldd "$BITCOIN_BINARY" 2>&1 | tee -a "$LOG_FILE"
fi

log "Bitcoin service generation completed."
