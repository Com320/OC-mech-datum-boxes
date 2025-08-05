#!/bin/bash
# utils.sh - Common utility functions for Datum Autopilot scripts

# USAGE NOTE:
# To use these functions in other scripts, source this file:
#   source ./utils.sh
# Do NOT run it directly unless you want to run the test suite.

# Define colors
export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export NC='\033[0m' # No Color

# Find the absolute path to the script directory regardless of how it's called
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    # Resolve $source until the file is no longer a symlink
    while [ -L "$source" ]; do
        local dir="$( cd -P "$( dirname "$source" )" && pwd )"
        source="$(readlink "$source")"
        # If $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
        [[ $source != /* ]] && source="$dir/$source"
    done
    # Get directory of the script
    echo "$( cd -P "$( dirname "$source" )" && pwd )"
}

# Set default settings file path using absolute path
SCRIPT_DIR=$(get_script_dir)
export SETTINGS_FILE="$SCRIPT_DIR/settings.json"


# Update a value in a JSON file (supports one-level dot notation for nested keys)
# Usage: update_json_value "key" "new_value" file
update_json_value() {
    local key="$1"
    local new_value="$2"
    local file="$3"

    if [ ! -f "$file" ]; then
        echo "Warning: File not found: $file" >&2
        return 1
    fi

    # Use jq for robust JSON updates
    if [[ "$key" == *"."* ]]; then
        jq --arg value "$new_value" ".${key} = \$value" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        jq --arg value "$new_value" ".\"$key\" = \$value" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi

    # Check if the update was successful
    if ! jq -e ".${key} == \"$new_value\"" "$file" > /dev/null; then
        echo "Warning: Failed to update $key in $file" >&2
        return 1
    fi
    return 0
}
export -f update_json_value


# JSON helper function using jq
read_json_value() {
    # Usage: read_json_value "key" file
    local key="$1"
    local file="$2"
    if [ ! -f "$file" ]; then
        echo "" # Return empty if file not found
        return 1
    fi
    # If key contains a dot, treat as nested (e.g., user.username)
    if [[ "$key" == *.* ]]; then
        jq -r ".${key} // empty" "$file"
    else
        jq -r ".\"$key\" // empty" "$file"
    fi
}
export -f read_json_value


# JSON helper function for boolean values using jq
read_json_bool() {
    # Usage: read_json_bool "key" file
    # Returns 0 (success) if value is "true", 1 (failure) if "false"
    local key="$1"
    local file="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    local value=""
    if [[ "$key" == *"."* ]]; then
        value=$(jq -r ".${key} // empty" "$file")
    else
        value=$(jq -r ".\"$key\" // empty" "$file")
    fi
    if [ "$value" == "true" ]; then
        return 0
    else
        return 1
    fi
}
export -f read_json_bool


# JSON helper function for arrays using jq
read_json_array() {
    # Usage: read_json_array "key" file
    local key="$1"
    local file="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    if [[ "$key" == *"."* ]]; then
        jq -r ".${key}[]?" "$file"
    else
        jq -r ".\"$key\"[]?" "$file"
    fi
}
export -f read_json_array

# Initialize logging
# This function sets up logging for a script and must be called before any logging occurs
# Usage: init_logging "script_name"
init_logging() {
    local script_name="$1"
    echo -e "[init_logging] INFO: Initializing logging for $script_name"
    
    # Check if settings file exists
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo -e "${RED}Settings file not found at $SETTINGS_FILE${NC}"
        echo -e "[init_logging] ERROR: Settings file not found at $SETTINGS_FILE"
        return 1
    fi

    # Read log path from settings
    local logpath=$(read_json_value "logpath" "$SETTINGS_FILE")
    if [ -z "$logpath" ]; then
        echo -e "${YELLOW}Could not determine logpath from settings.json. Using default '/var/log/datum-ap'${NC}"
        echo -e "[init_logging] WARNING: Could not determine logpath from settings.json. Using default '/var/log/datum-ap'"
        logpath="/var/log/datum-ap"
    fi

    # If logpath is not absolute, resolve based on user
    if [[ "$logpath" != /* ]]; then
        if [ "$(id -u)" -eq 0 ]; then
            # root: use script directory as base
            logpath="$SCRIPT_DIR/$logpath"
            echo -e "[init_logging] INFO: Using relative logpath as root, resolved to $logpath"
        else
            # non-root: use home directory as base
            user_home=$(eval echo ~$(whoami))
            logpath="$user_home/$logpath"
            echo -e "[init_logging] INFO: Using relative logpath as non-root, resolved to $logpath"
        fi
    fi

    # Create log directory if it doesn't exist
    mkdir -p "$logpath"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to create log directory at $logpath${NC}"
        echo -e "[init_logging] ERROR: Failed to create log directory at $logpath"
        return 1
    fi

    # Set log file global variable
    LOG_FILE="${logpath}/${script_name}.log"
    if ! touch "$LOG_FILE"; then
        echo -e "${RED}Failed to create log file at $LOG_FILE${NC}"
        echo -e "[init_logging] ERROR: Failed to create log file at $LOG_FILE"
        return 1
    fi

    # Export LOG_FILE so it is available to all child processes and subshells
    export LOG_FILE

    echo -e "[init_logging] INFO: Logging initialized for $script_name"
    echo -e "[init_logging] INFO: Log file: $LOG_FILE"
    echo -e "[init_logging] INFO: Settings file: $SETTINGS_FILE"

    # Log initialization
    log "Logging initialized for $script_name"
    log "Log file: $LOG_FILE"

    return 0
}

# Log function (writes messages with a timestamp to log file only)
# Usage: log "message"
log() {
    local msg="$1"
    if [ -n "$LOG_FILE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"
    else
        # If LOG_FILE is not set yet, just echo to console
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
    fi
}
export -f log

# Log and display function (logs to file and displays on screen)
# Usage: log_display "message"
log_display() {
    local msg="$1"
    echo -e "$msg"
    log "$msg"
}
export -f log_display

# Get username from settings or prompt user
# Usage: get_username
get_username() {
    local username
    username=$(read_json_value "user.username" "$SETTINGS_FILE")

    if [ -z "$username" ]; then
        log "${RED}Could not determine username from settings.json.${NC}"
        echo -e "${RED}Could not determine username from settings.json.${NC}" >&2
        while true; do
            printf "Enter the username: " >&2
            read user_input
            user_input=$(echo "$user_input" | xargs)
            log "User entered: $user_input"
            printf "Is this correct? (y/n): " >&2
            read confirm
            if [ "$confirm" = "y" ]; then
                username="$user_input"
                update_json_value "user.username" "$username" "$SETTINGS_FILE"
                log "Updated settings.json with new username: $username"
                echo -e "${YELLOW}Settings file updated with new username: $username${NC}" >&2
                break
            fi
            log "User requested to try again"
            printf "Let's try again.\n" >&2
        done
    else
        log "Found username in settings.json: $username"
        printf "Using username from settings.json: $username\n" >&2
        printf "Is this correct? (y/n): " >&2
        read confirm
        if [ "$confirm" != "y" ]; then
            log "User rejected the username from settings"
            while true; do
                printf "Enter the username: " >&2
                read user_input
                user_input="$(echo "$user_input" | xargs)"
                log "User entered: $user_input"
                printf "Is this correct? (y/n): " >&2
                read confirm
                if [ "$confirm" = "y" ]; then
                    username="$user_input"
                    update_json_value "user.username" "$username" "$SETTINGS_FILE"
                    log "Updated settings.json with new username: $username"
                    echo -e "${YELLOW}Settings file updated with new username: $username${NC}" >&2
                    break
                fi
                log "User requested to try again"
                printf "Let's try again.\n" >&2
            done
        fi
    fi

    username="$(echo "$username" | xargs)"
    if [ -z "$username" ]; then
        log "${RED}Username must be provided.${NC}"
        echo -e "${RED}Username must be provided.${NC}" >&2
        return 1
    fi
    if ! getent passwd "$username" > /dev/null 2>&1; then
        log "${RED}User $username does not exist. Please create the user first.${NC}"
        echo -e "${RED}User $username does not exist. Please create the user first.${NC}" >&2
        return 1
    fi
    log "Username verified: $username"
    printf "%s" "$username"
}

# Get home directory for a user
# Usage: get_home_directory "username"
get_home_directory() {
    local username="$1"

    if [ -z "$username" ]; then
        log_display "${RED}No username provided to get_home_directory function.${NC}"
        return 1
    fi

    # Try multiple methods to get home directory
    local home_dir=""

    # Method 1: getent passwd
    if command -v getent &> /dev/null; then
        home_dir=$(getent passwd "$username" 2>/dev/null | cut -d: -f6)
    fi

    # Method 2: eval echo ~ (if Method 1 failed)
    if [ -z "$home_dir" ]; then
        home_dir=$(eval echo "~$username" 2>/dev/null)
    fi

    # Method 3: check /etc/passwd directly (if all else fails)
    if [ -z "$home_dir" ] && [ -f "/etc/passwd" ]; then
        home_dir=$(grep "^$username:" /etc/passwd 2>/dev/null | cut -d: -f6)
    fi

    # Verify we have a result
    if [ -z "$home_dir" ]; then
        log_display "${RED}Could not determine home directory for user $username.${NC}"
        return 1
    fi

    # Verify the directory exists
    if [ ! -d "$home_dir" ]; then
        log_display "${RED}Home directory for $username does not exist: $home_dir${NC}"
        log_display "${YELLOW}Note: The user exists but their home directory is missing.${NC}"
        return 1
    fi

    # Return the home directory
    log "Home directory for $username: $home_dir"
    echo "$home_dir"
}

# Function to test utils.sh when run directly
test_utils() {
    echo -e "\n${GREEN}===== Utility Functions Test =====${NC}\n"
    
    # Test basic variables
    echo -e "${GREEN}Basic Information:${NC}"
    echo "Script directory: $SCRIPT_DIR"
    echo "Settings file: $SETTINGS_FILE"
    
    # Test settings file detection
    if [ -f "$SETTINGS_FILE" ]; then
        echo -e "${GREEN}Settings file found at $SETTINGS_FILE${NC}"
    else
        echo -e "${RED}Settings file NOT found at $SETTINGS_FILE${NC}"
        echo "Please create a settings.json file in the same directory as utils.sh"
        return 1
    fi

        # Robust tree view: print all key paths and values, indented by depth (compatible with older jq)
        echo -e "\n${GREEN}Dumping all key-value pairs in settings.json (tree view):${NC}"
        jq -r '
            paths(scalars) as $p
            | (reduce range(0; ($p | length)-1) as $i (""; . + "\t"))
                + ([ $p[] | tostring ] | join("."))
                + ": "
                + (getpath($p) | tostring)
        ' "$SETTINGS_FILE"

    # Test read_json_value function with username and logpath
    echo -e "\n${GREEN}Testing read_json_value() function:${NC}"
    echo "Username from settings: $(read_json_value "user.username" "$SETTINGS_FILE")"
    echo "Log path from settings: $(read_json_value "logpath" "$SETTINGS_FILE")"
    
    # Initialize logging for testing
    echo -e "\n${GREEN}Testing init_logging() function:${NC}"
    init_logging "utils_test"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Logging initialized successfully${NC}"
        echo "Log file: $LOG_FILE"
    else
        echo -e "${RED}Failed to initialize logging${NC}"
    fi
    
    # Test log functions
    echo -e "\n${GREEN}Testing log() and log_display() functions:${NC}"
    log "This is a test log message (written to log file only)"
    log_display "This is a test log display message (written to screen and log file)"
    
    # Test username functions
    echo -e "\n${GREEN}Testing get_username() function:${NC}"
    echo "The following will ask for confirmation of the username from settings.json."
    echo "Please respond to continue the test."
    username=$(get_username)
    if [ $? -eq 0 ]; then
        echo -e "Username verified: ${GREEN}$username${NC}"
        
        # Test home directory function
        echo -e "\n${GREEN}Testing get_home_directory() function:${NC}"
        user_home=$(get_home_directory "$username")
        if [ $? -eq 0 ]; then
            echo -e "Home directory found: ${GREEN}$user_home${NC}"
            
            # For Bitcoin users, check service template
            if [[ "$username" == "bitcoin" ]]; then
                template_path="$user_home/bitcoin/src/bitcoin/contrib/init/bitcoind.service"
                echo -e "\n${GREEN}Testing path to Bitcoin service template:${NC}"
                if [ -f "$template_path" ]; then
                    echo -e "Template found: ${GREEN}$template_path${NC}"
                    echo "First 5 lines of template:"
                    head -n 5 "$template_path"
                else
                    echo -e "${RED}Template not found at $template_path${NC}"
                    echo "This may cause the generate-bitcoin-service.sh script to fall back to the simplified template."
                fi
            fi

            # Check Datum paths
            echo -e "\n${GREEN}Testing Datum paths:${NC}"
            datum_config="$user_home/datum/datum_gateway_config.json"
            datum_executable="$user_home/datum/bin/datum_gateway"

            if [ -f "$datum_config" ]; then
                echo -e "Datum config found: ${GREEN}$datum_config${NC}"
            else
                echo -e "${RED}Datum config not found at $datum_config${NC}"
            fi

            if [ -f "$datum_executable" ]; then
                echo -e "Datum executable found: ${GREEN}$datum_executable${NC}"
            else
                echo -e "${RED}Datum executable not found at $datum_executable${NC}"
            fi
        else
            echo -e "${RED}Failed to get home directory for $username${NC}"
        fi
    else
        echo -e "${RED}Failed to verify username${NC}"
    fi
    
    echo -e "\n${GREEN}===== Utility Test Complete =====${NC}\n"
}

# If this script is being run directly (not sourced), run the test function and exit
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    test_utils
    exit 0
fi