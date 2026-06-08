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
    
    # Get the path to scripts from settings.json, try both configured and all-lowercase variant
    local script_dir=$(read_json_value "scripts_path" "$SETTINGS_FILE")
    if [ -z "$script_dir" ]; then
        log "${YELLOW}Could not determine scripts_path from settings.json. Using default '/root/OC-mech-datum-boxes'.${NC}"
        script_dir="/root/OC-mech-datum-boxes"
    fi

    # Prepare candidate paths: configured and lowercased
    local script_dir_lc
    script_dir_lc=$(echo "$script_dir" | tr '[:upper:]' '[:lower:]')

    local verify_script=""
    local utils_script=""
    local settings_file=""

    # Prefer the configured path if it contains the verify script
    if [ -f "$script_dir/verify-git-tag.sh" ]; then
        verify_script="$script_dir/verify-git-tag.sh"
        utils_script="$script_dir/utils.sh"
        settings_file="$script_dir/settings.json"
        log "Using scripts_path from settings.json: $script_dir"
    elif [ "$script_dir_lc" != "$script_dir" ] && [ -f "$script_dir_lc/verify-git-tag.sh" ]; then
        # Fall back to lowercase variant (some clones may create a lowercase path)
        verify_script="$script_dir_lc/verify-git-tag.sh"
        utils_script="$script_dir_lc/utils.sh"
        settings_file="$script_dir_lc/settings.json"
        log "Using lowercase scripts_path variant: $script_dir_lc"
    else
        log "${RED}Error: Verification script not found in configured scripts_path ($script_dir) nor in lowercase variant ($script_dir_lc)${NC}"
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

# Determine major version from tag (expects something like v28.1.knots20250305 or v29.0)
extract_major_version() {
    local tag="$1"
    # Strip leading 'v' if present, then take first number sequence
    tag="${tag#v}"
    # Use parameter expansion to split on non-digit
    local major
    major=$(echo "$tag" | sed -E 's/[^0-9].*$//' )
    if [[ ! $major =~ ^[0-9]+$ ]]; then
        echo 0
    else
        echo "$major"
    fi
}

major_version=$(extract_major_version "$bitcoin_knots_tag")
log "Detected major version: $major_version from tag $bitcoin_knots_tag"

USE_CMAKE=false
if [ "$major_version" -ge 29 ]; then
    USE_CMAKE=true
    log "Using CMake build path for version >=29"
else
    log "Using Autotools build path for version <29"
fi

if [ "$USE_CMAKE" = true ]; then
    # CMake build path
    build_dir="build"
    cmake_args=(
        -DBUILD_TESTS=OFF \
        -DBUILD_WALLET_TOOL=OFF \
        -DWITH_ZMQ=OFF \
        -DRDTS_CONSENT=IMPLICIT
    )

    # If tests requested, adjust
    if [ "$RUN_TESTS_BOOL" = true ]; then
        # Assuming future CMake option name; adjust if upstream differs
        cmake_args=("${cmake_args[@]/-DBUILD_TESTS=OFF/-DBUILD_TESTS=ON}")
        log "Tests enabled: switching -DBUILD_TESTS=ON for CMake"
    fi

    # Toolchain file (musl) detection - only add if present
    toolchain_file="depends/x86_64-pc-linux-musl/toolchain.cmake"
    if [ -f "$bitcoin_src/$toolchain_file" ]; then
        cmake_toolchain_arg=(--toolchain "$toolchain_file")
        log "Found toolchain file: $toolchain_file"
    else
        cmake_toolchain_arg=()
        log "No toolchain file found at $toolchain_file (continuing without it)."
    fi

    log "Configuring with CMake..."
    if su - "$username" -c "cd $bitcoin_src && cmake -B $build_dir ${cmake_toolchain_arg[*]} ${cmake_args[*]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "CMake configure completed successfully."
    else
        log "CMake configure failed."; exit 1
    fi

    log "Building with CMake -j$cpu_cores..."
    if su - "$username" -c "cd $bitcoin_src && cmake --build $build_dir -j $cpu_cores" 2>&1 | tee -a "$LOG_FILE"; then
        log "CMake build completed successfully."
    else
        log "CMake build failed."; exit 1
    fi

    if [ "$RUN_TESTS_BOOL" = true ]; then
        # Placeholder for future CTest integration
        if command -v ctest >/dev/null 2>&1; then
            log_display "Running CTest..."
            if su - "$username" -c "cd $bitcoin_src/$build_dir && ctest --output-on-failure" 2>&1 | tee -a "$LOG_FILE"; then
                log_display "${GREEN}CTest completed successfully.${NC}"
            else
                log_display "${RED}Error: CTest failed. See log for details.${NC}"; exit 1
            fi
        else
            log_display "${YELLOW}ctest not found; skipping tests although RUN_TESTS is true.${NC}"
        fi
    else
        log_display "${YELLOW}Skipping tests (run_tests configured as: $run_tests_raw).${NC}"
    fi

    # Set paths for binaries under CMake build.
    # Observed actual layout: $bitcoin_src/$build_dir/bin/bitcoind (as per user logs)
    built_binary="$bitcoin_src/$build_dir/bin/bitcoind"
    cli_binary="$bitcoin_src/$build_dir/bin/bitcoin-cli"

    # If the expected bin path does not exist, attempt to auto-detect alternative locations.
    if [ ! -x "$built_binary" ]; then
        log "Primary expected CMake binary path not found: $built_binary. Attempting discovery..."
        # Search limited to build dir for speed
        detected_bitcoind=$(su - "$username" -c "find '$bitcoin_src/$build_dir' -maxdepth 4 -type f -name bitcoind 2>/dev/null | head -n1")
        if [ -n "$detected_bitcoind" ] && su - "$username" -c "test -x '$detected_bitcoind'"; then
            built_binary="$detected_bitcoind"
            log "Discovered bitcoind at: $built_binary"
        else
            log "Could not locate bitcoind within $bitcoin_src/$build_dir via discovery.";
        fi
        detected_cli=$(su - "$username" -c "find '$bitcoin_src/$build_dir' -maxdepth 4 -type f -name bitcoin-cli 2>/dev/null | head -n1")
        if [ -n "$detected_cli" ] && su - "$username" -c "test -x '$detected_cli'"; then
            cli_binary="$detected_cli"
            log "Discovered bitcoin-cli at: $cli_binary"
        fi
    fi
else
    # Autotools path (existing logic)
    log "Running autogen.sh..."
    if su - "$username" -c "cd $bitcoin_src && ./autogen.sh" 2>&1 | tee -a "$LOG_FILE"; then
        log "autogen.sh completed successfully."
    else
        log "autogen.sh failed."; exit 1
    fi

    log "Running configure with --disable-wallet..."
    configure_args="--disable-zmq --disable-wallet --prefix=$bitcoin_dir"
    if [ "$RUN_TESTS_BOOL" != true ]; then
        configure_args="$configure_args --disable-tests"
        log "Tests disabled; adding --disable-tests to configure"
    fi

    if su - "$username" -c "cd $bitcoin_src && ./configure $configure_args" 2>&1 | tee -a "$LOG_FILE"; then
        log "Configure completed successfully."
    else
        log "Configure failed."; exit 1
    fi

    log "Running make -j$cpu_cores..."
    if su - "$username" -c "cd $bitcoin_src && make -j$cpu_cores" 2>&1 | tee -a "$LOG_FILE"; then
        log "make completed successfully."
    else
        log "make failed."; exit 1
    fi

    if [ "$RUN_TESTS_BOOL" = true ]; then
        log_display "Running tests..."
        if su - "$username" -c "cd $bitcoin_src && make check" 2>&1 | tee -a "$LOG_FILE"; then
            log_display "${GREEN}Tests completed successfully.${NC}"
        else
            log_display "${RED}Error: Tests failed. See log for details.${NC}"; exit 1
        fi
    else
        log_display "${YELLOW}Skipping tests (run_tests configured as: $run_tests_raw).${NC}"
    fi

    built_binary="$bitcoin_src/src/bitcoind"
    cli_binary="$bitcoin_src/src/bitcoin-cli"
fi

# The binary path is decided by build system above
log "Checking binary at known path: $built_binary"
if su - "$username" -c "test -f $built_binary && test -x $built_binary"; then
    log "Verified: Binary exists and is executable at $built_binary"
else
    log "${RED}Error: Binary not found or not executable at expected location: $built_binary${NC}"
    log "Searching for binary in alternative locations..."
    su - "$username" -c "find $bitcoin_src -name 'bitcoind' -type f" | tee -a "$LOG_FILE"
    exit 1
fi

# Repeat the same checks for bitcoin-cli (cli_binary already set in build path)
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
