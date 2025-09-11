#!/bin/bash
# This script builds Bitcoin Knots with --disable-wallet.
# It assumes dependencies were installed by a previous step.
# NOTE: This script is intended to be invoked by main.sh and should not be run on its own.


# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Get username from settings.json using utils.sh JSON parser

username=$(read_json_value "user.username" "$SETTINGS_FILE")
if [ -z "$username" ]; then
    log_display "${RED}Could not determine username from settings.json. Using default 'bitcoin'.${NC}"
    username="bitcoin"
    log "Using default username: $username"
fi

# Get user's home directory using utils.sh function
user_home=$(get_home_directory "$username")
if [ -z "$user_home" ] || [ ! -d "$user_home" ]; then
    log_display "${RED}User home directory for $username not found. Aborting.${NC}"
    exit 1
fi

# Initialize logging
init_logging "build-btcknots"

# Read the CPU cores setting (default to 4 if not found)
cpu_cores=$(read_json_value "build_options.cpu_cores" "$SETTINGS_FILE")
if [ -z "$cpu_cores" ]; then
    log_display "${RED}Could not determine cpu_cores from settings.json. Using default '4'.${NC}"
    cpu_cores=4
    log "Using default cpu_cores: $cpu_cores"
fi

# Read run_tests setting (default to true if not found)
run_tests_raw=$(read_json_value "build_options.run_tests" "$SETTINGS_FILE")
if [ -z "$run_tests_raw" ]; then
    log_display "${YELLOW}Could not determine run_tests from settings.json. Using default 'true'.${NC}"
    run_tests_raw=true
    RUN_TESTS_BOOL=true
    log "Using default run_tests: $run_tests_raw"
else
    if read_json_bool "build_options.run_tests" "$SETTINGS_FILE"; then
        RUN_TESTS_BOOL=true
    else
        RUN_TESTS_BOOL=false
    fi
fi

# Read Bitcoin Knots tag to checkout (default to v28.1.knots20250305 if not found)
bitcoin_knots_tag=$(read_json_value "build_options.bitcoin_knots_tag" "$SETTINGS_FILE")
if [ -z "$bitcoin_knots_tag" ]; then
    log_display "${RED}Could not determine bitcoin_knots_tag from settings.json. Using default 'v28.1.knots20250305'.${NC}"
    bitcoin_knots_tag="v28.1.knots20250305"
    log "Using default bitcoin_knots_tag: $bitcoin_knots_tag"
fi

# Read signature verification setting (default to true if not found)
verify_signatures=$(read_json_value "build_options.verify_signatures" "$SETTINGS_FILE")
if [ -z "$verify_signatures" ]; then
    log_display "${YELLOW}Could not determine verify_signatures from settings.json. Using default 'true'.${NC}"
    verify_signatures=true
    log "Using default verify_signatures: $verify_signatures"
fi

# Read key fingerprint (default if not found)
key_fingerprint=$(read_json_value "build_options.key_fingerprint" "$SETTINGS_FILE")
if [ -z "$key_fingerprint" ]; then
    log_display "${YELLOW}Could not determine key_fingerprint from settings.json. Using default '1A3E761F19D2CC7785C5502EA291A2C45D0C504A'.${NC}"
    key_fingerprint="1A3E761F19D2CC7785C5502EA291A2C45D0C504A"
fi

# Verify function for checking git tag signature
verify_git_tag() {
    local repo_path="$1"
    local tag="$2"
    local fingerprint="$3"
    
    log "Verifying signature for tag: $tag"
      # Check if we have gnupg installed
    if ! command -v gpg &> /dev/null; then
        log "${RED}Error: GPG is not installed. Please run dependencies.sh first or restart the entire setup process.${NC}"
        return 1
    fi
    
    # Get the path to scripts from settings.json, default to /root/OC-mech-datum-boxes if not found
    local script_dir=$(read_json_value "scripts_path" "$SETTINGS_FILE")
    if [ -z "$script_dir" ]; then
        log "${YELLOW}Could not determine scripts_path from settings.json. Using default '/root/OC-mech-datum-boxes'.${NC}"
        script_dir="/root/OC-mech-datum-boxes"
    fi
    
    local verify_script="$script_dir/verify-git-tag.sh"
    local utils_script="$script_dir/utils.sh"
    local settings_file="$script_dir/settings.json"
    
    if [ ! -f "$verify_script" ]; then
        log "${RED}Error: Verification script not found at $verify_script${NC}"
        return 1
    fi
    
    # Copy the script to a location where the bitcoin user can access it
    local user_script="$user_home/verify-git-tag.sh"
    local user_utils="$user_home/utils.sh"
    local user_settings="$user_home/settings.json"
    
    # Copy the verification script, utils.sh, and settings.json
    cp "$verify_script" "$user_script"
    cp "$utils_script" "$user_utils"
    cp "$settings_file" "$user_settings"
    
    # Set proper ownership and permissions
    chown "$username:$username" "$user_script" "$user_utils" "$user_settings"
    chmod 755 "$user_script" "$user_utils"
    chmod 644 "$user_settings"
    
    # Create a log file path that the bitcoin user can write to
    local user_log_file="$user_home/.verify-git-tag.log"
    touch "$user_log_file"
    chown "$username:$username" "$user_log_file"
    
    # Run the verification script as the repository owner, passing the log file path
    log "Running verification as user $username using script at $user_script"
    su - "$username" -c "$user_script \"$repo_path\" \"$tag\" \"$fingerprint\" \"$user_log_file\""
    local result=$?
    
    # Copy the content from the user log file to our main log file
    if [ -f "$user_log_file" ]; then
        cat "$user_log_file" >> "$LOG_FILE"
        rm -f "$user_log_file"
    fi
    
    # Clean up the temporary script
    rm -f "$user_script"
    
    if [ $result -eq 0 ]; then
        log "Signature verification successful for tag: $tag"
        return 0
    else
        log "Signature verification failed for tag: $tag"
        return 1
    fi
}

# Main Execution
log "Starting Bitcoin Knots build process..."
log "Using Bitcoin Knots tag: $bitcoin_knots_tag"
log "Using $cpu_cores CPU cores for build"
if [ "$verify_signatures" = true ]; then
    log "Signature verification is ENABLED"
else
    log "Signature verification is DISABLED"
fi

# Create directories
bitcoin_dir="$user_home/bitcoin"
src_dir="$bitcoin_dir/src"
bin_dir="$bitcoin_dir/bin"

log "Creating directories..."
mkdir -p "$src_dir"
mkdir -p "$bin_dir"
chown -R "$username:$username" "$bitcoin_dir"

# Move into source-code directory
log "Changing directory to $src_dir..."
cd "$src_dir" || { log "Failed to change directory to $src_dir."; exit 1; }

# Clone the bitcoin repository
log "Cloning Bitcoin Knots repository from GitHub..."
if su - "$username" -c "cd $src_dir && git clone https://github.com/bitcoinknots/bitcoin.git" 2>&1 | tee -a "$LOG_FILE"; then
    log "Bitcoin Knots repository cloned successfully."
else
    log "Failed to clone Bitcoin Knots repository."
    exit 1
fi

# Change directory into the repository
bitcoin_src="$src_dir/bitcoin"
log "Changing directory to bitcoin..."
cd "$bitcoin_src" || { log "Failed to change directory to bitcoin/"; exit 1; }

# Checkout the specified tag
log "Checking out tag: $bitcoin_knots_tag..."
if su - "$username" -c "cd $bitcoin_src && git fetch --tags && git checkout $bitcoin_knots_tag" 2>&1 | tee -a "$LOG_FILE"; then
    log "Tag checkout completed successfully."
else
    log "Tag checkout failed. The specified tag may not exist."
    exit 1
fi

# Verify tag signature if enabled
if [ "$verify_signatures" = true ]; then
    if verify_git_tag "$bitcoin_src" "$bitcoin_knots_tag" "$key_fingerprint"; then
        log "Signature verification passed. Proceeding with build."
    else
        log "Signature verification failed. Aborting build for security reasons."
        exit 1
    fi
fi

# Run autogen.sh
log "Running autogen.sh..."
if su - "$username" -c "cd $bitcoin_src && ./autogen.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log "autogen.sh completed successfully."
else
    log "autogen.sh failed."
    exit 1
fi

# Run configure with --disable-wallet --disable-zmq options
log "Running configure with --disable-wallet..."
if su - "$username" -c "cd $bitcoin_src && ./configure --disable-zmq --disable-wallet --prefix=$bitcoin_dir" 2>&1 | tee -a "$LOG_FILE"; then
    log "Configure completed successfully."
else
    log "Configure failed."
    exit 1
fi

# Run make with the specified number of CPU cores
log "Running make -j$cpu_cores..."
if su - "$username" -c "cd $bitcoin_src && make -j$cpu_cores" 2>&1 | tee -a "$LOG_FILE"; then
    log "make completed successfully."
else
    log "make failed."
    exit 1
fi

# Conditionally run make check/tests
if [ "$RUN_TESTS_BOOL" = true ]; then
    log_display "Running tests..."
    if su - "$username" -c "cd $bitcoin_src && make check" 2>&1 | tee -a "$LOG_FILE"; then
        log_display "${GREEN}Tests completed successfully.${NC}"
    else
        log_display "${RED}Error: Tests failed. See log for details.${NC}"
        exit 1
    fi
else
    log_display "${YELLOW}Skipping tests (run_tests configured as: $run_tests_raw).${NC}"
fi

# The binary is located at a known path after build
built_binary="$bitcoin_src/src/bitcoind"
log "Checking binary at known path: $built_binary"
if su - "$username" -c "test -f $built_binary && test -x $built_binary"; then
    log "Verified: Binary exists and is executable at $built_binary"
else
    log "${RED}Error: Binary not found or not executable at expected location: $built_binary${NC}"
    log "Searching for binary in alternative locations..."
    su - "$username" -c "find $bitcoin_src -name 'bitcoind' -type f" | tee -a "$LOG_FILE"
    exit 1
fi

# Repeat the same checks for bitcoin-cli
cli_binary="$bitcoin_src/src/bitcoin-cli"
log "Checking bitcoin-cli binary at known path: $cli_binary"
if su - "$username" -c "test -f $cli_binary && test -x $cli_binary"; then
    log "Verified: bitcoin-cli exists and is executable at $cli_binary"
else
    log "${RED}Error: bitcoin-cli not found or not executable at expected location: $cli_binary${NC}"
    log "Searching for bitcoin-cli binary in alternative locations..."
    su - "$username" -c "find $bitcoin_src -name 'bitcoin-cli' -type f" | tee -a "$LOG_FILE"
    exit 1
fi

# Create bin directory if it doesn't exist
log "Ensuring bin directory exists at $bin_dir"
mkdir -p "$bin_dir"
chown -R "$username:$username" "$bin_dir"

# Copy binary to user's bin directory
log "Copying binary to user's bin directory..."
if su - "$username" -c "cp $built_binary $bin_dir/" 2>&1 | tee -a "$LOG_FILE"; then
    log "Binary copied to $bin_dir/bitcoind successfully."
else
    log "${RED}Error: Failed to copy binary to $bin_dir/bitcoind${NC}"
    exit 1
fi

# Copy bitcoin-cli to user's bin directory
log "Copying bitcoin-cli to user's bin directory..."
if su - "$username" -c "cp $cli_binary $bin_dir/" 2>&1 | tee -a "$LOG_FILE"; then
    log "bitcoin-cli copied to $bin_dir/bitcoin-cli successfully."
else
    log "${RED}Error: Failed to copy bitcoin-cli to $bin_dir/bitcoin-cli${NC}"
    exit 1
fi

# Install the binary directly to /usr/local/bin for system-wide accessibility
log "Installing binary to /usr/local/bin..."
if cp "$built_binary" /usr/local/bin/bitcoind 2>&1 | tee -a "$LOG_FILE"; then
    log "Binary copied to /usr/local/bin/bitcoind successfully."
else
    log "${RED}Error: Failed to copy binary to /usr/local/bin/bitcoind${NC}"
    exit 1
fi

# Install bitcoin-cli to /usr/local/bin for system-wide accessibility
log "Installing bitcoin-cli to /usr/local/bin..."
if cp "$cli_binary" /usr/local/bin/bitcoin-cli 2>&1 | tee -a "$LOG_FILE"; then
    log "bitcoin-cli copied to /usr/local/bin/bitcoin-cli successfully."
else
    log "${RED}Error: Failed to copy bitcoin-cli to /usr/local/bin/bitcoin-cli${NC}"
    exit 1
fi

# Set proper ownership and permissions
log "Setting permissions on binary..."
if chown root:root /usr/local/bin/bitcoind; then
    log "Binary ownership set to root:root."
else
    log "${RED}Error: Failed to set binary ownership${NC}"
    exit 1
fi

if chmod 755 /usr/local/bin/bitcoind; then
    log "Binary permissions set to 755."
else
    log "${RED}Error: Failed to set binary permissions${NC}"
    exit 1
fi

# Set proper ownership and permissions for bitcoin-cli
if chown root:root /usr/local/bin/bitcoin-cli; then
    log "bitcoin-cli ownership set to root:root."
else
    log "${RED}Error: Failed to set bitcoin-cli ownership${NC}"
    exit 1
fi

if chmod 755 /usr/local/bin/bitcoin-cli; then
    log "bitcoin-cli permissions set to 755."
else
    log "${RED}Error: Failed to set bitcoin-cli permissions${NC}"
    exit 1
fi

# Verify the binary works
log "Verifying binary..."
if /usr/local/bin/bitcoind --version | head -n1 >> "$LOG_FILE" 2>&1; then
    log "Binary is working correctly."
else
    log "${RED}Error: Cannot execute bitcoind. Check library dependencies:${NC}"
    ldd /usr/local/bin/bitcoind >> "$LOG_FILE" 2>&1 || echo "ldd command failed" >> "$LOG_FILE"
    file /usr/local/bin/bitcoind >> "$LOG_FILE" 2>&1
    exit 1
fi

# Verify bitcoin-cli works
log "Verifying bitcoin-cli..."
if /usr/local/bin/bitcoin-cli --version | head -n1 >> "$LOG_FILE" 2>&1; then
    log "bitcoin-cli is working correctly."
else
    log "${RED}Error: Cannot execute bitcoin-cli. Check library dependencies:${NC}"
    ldd /usr/local/bin/bitcoin-cli >> "$LOG_FILE" 2>&1 || echo "ldd command failed" >> "$LOG_FILE"
    file /usr/local/bin/bitcoin-cli >> "$LOG_FILE" 2>&1
    exit 1
fi

log "Bitcoin Knots build process completed."
