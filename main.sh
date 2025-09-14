#!/bin/bash
# This script drives the overall install process.
# It installs dependencies, builds Bitcoin Knots, and builds Datum Gateway.
# Run this script from the project's root directory.


# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Helper: print instructions to run a proper root shell, remove dirty marker, and exit
require_root_shell() {
  echo -e "${RED}This script must be run as root directly, not with 'sudo <script>'.${NC}"
  echo "To switch to root, run one of the following:"
  echo "  sudo -i"
  echo "  su -"
  echo "Or log in as root directly if enabled."
  echo "Then run this script again from the root shell."
  # We didn't perform any work in this run — clear the dirty marker if present and exit
  rm -f "$DIRTY_MARKER" 2>/dev/null || true
  exit 1
}

# Dirty marker file path in the running user's home directory
USER_HOME=$(eval echo ~$(id -un))
DIRTY_MARKER="$USER_HOME/.datum_inst"

# Check for dirty marker file before anything else
if [ -f "$DIRTY_MARKER" ]; then
  RUN_DATE=$(head -n 1 "$DIRTY_MARKER")
  echo -e "${RED}WARNING: This script was previously run on $RUN_DATE and exited uncleanly. This can cause problems with the tools and services it installs.\nIt is strongly recommended to wipe and reinstall the operating system before continuing.${NC}"
  if ! confirm_prompt "Do you want to proceed anyway? (y/n): "; then
    echo "Exiting as requested."
    exit 1
  fi
fi

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
  echo -e "${YELLOW}jq not found. Installing jq...${NC}"
  apt-get update && apt-get install -y jq
  if [ $? -ne 0 ]; then
    echo "jq installation failed. Exiting."
    exit 1
  fi
else
  echo "jq is already installed."
fi

# Check if running as root, sudo, or neither
if [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ]; then
  require_root_shell
elif [ "$(id -u)" -eq 0 ]; then
  echo -e "${GREEN}Running as root (not via sudo).${NC}"
else
  require_root_shell
fi

# Environment sanity check: ensure administrative tools like useradd are visible
if ! command -v useradd >/dev/null 2>&1; then
  echo -e "${YELLOW}Warning: 'useradd' not found in PATH. Your environment may not be a full root shell (sbin dirs may be missing from PATH).${NC}"
  echo "This can happen if you ran the script with 'sudo <script>' rather than entering a root shell."
  echo "Some people use plain 'su' (without the dash) and it may appear to work, but that does not always set a full login environment; /sbin and /usr/sbin may still be missing from PATH."
  echo "Recommended ways to get a proper root environment and re-run this script:"
  echo "  sudo -i     # start an interactive login shell as root"
  echo "  su -        # start a login shell as root (sets PATH and environment)"
  echo "After switching to one of the recommended methods, run this script again from the root shell."
  # We didn't perform any work in this run — clear the dirty marker if present and exit
  rm -f "$DIRTY_MARKER" 2>/dev/null || true
  exit 1
fi

# Create dirty marker file with run date/time at the start of important operations
echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$DIRTY_MARKER"

# Initialize logging
init_logging "main"

ERRORS=0
ERROR_LOG=""

# Function to track errors
track_error() {
  local step=$1
  local ret_val=$2
  
  if [ $ret_val -ne 0 ]; then
    ERRORS=$((ERRORS+1))
    ERROR_LOG="${ERROR_LOG}\n- Error in ${step}"
    log_display "${RED}${step} failed. Continuing with next step...${NC}"
    return 1
  fi
  log_display "${GREEN}${step} completed successfully.${NC}"
  return 0
}

# Display welcome message
source "$SCRIPT_DIR/welcomemsg.sh"

# Set up the user from settings.json
log_display "Setting up user..."
"$SCRIPT_DIR/user-setup.sh"
track_error "User setup" $?

log_display "Installing dependencies..."
"$SCRIPT_DIR/dependencies.sh"
track_error "Dependencies installation" $?

log_display "Building Bitcoin Knots..."
"$SCRIPT_DIR/build-btcknots.sh"
track_error "Bitcoin Knots build" $?

log_display "Building Datum Gateway..."
"$SCRIPT_DIR/build-datum.sh"
track_error "Datum Gateway build" $?

echo "Generating RPC authentication..."
"$SCRIPT_DIR/generate-rpcauth.sh"
track_error "RPC authentication generation" $?

echo "Generating Bitcoin configuration..."
"$SCRIPT_DIR/bitcoin-conf-generator.sh"
track_error "Bitcoin configuration generation" $?

echo "Generating Datum configuration..."
"$SCRIPT_DIR/datum-config-generator.sh"
track_error "Datum configuration generation" $?

echo "Generating Bitcoin service..."
"$SCRIPT_DIR/generate-bitcoin-service.sh"
track_error "Bitcoin service generation" $?

echo "Generating Datum service..."
"$SCRIPT_DIR/generate-datum-service.sh"
track_error "Datum service generation" $?

# Print final summary
echo "-----------------------------------------"
# Copy user log files to root's log directory for collection

# Use scripts_path and logpath from settings.json for destination
user=$(read_json_value "user.username" "$SETTINGS_FILE")
logpath=$(read_json_value "logpath" "$SETTINGS_FILE")
scripts_path=$(read_json_value "scripts_path" "$SETTINGS_FILE")
if [ -z "$logpath" ]; then
  logpath="datum_instlogs"
fi
if [ -z "$scripts_path" ]; then
  scripts_path="/root/OC-mech-datum-boxes"
fi
user_logdir="/home/$user/$logpath"
dest_dir="$scripts_path/$logpath/from_${user}"
mkdir -p "$dest_dir"
echo "Copying user logs from $user_logdir to $dest_dir..."
copied_files=()
if [ -d "$user_logdir" ]; then
  for f in "$user_logdir"/*; do
    if [ -f "$f" ]; then
      cp "$f" "$dest_dir/"
      copied_files+=("$dest_dir/$(basename "$f")")
    fi
  done
fi
if [ ${#copied_files[@]} -gt 0 ]; then

  echo "Copied the following user log files to $dest_dir:"
  for f in "${copied_files[@]}"; do
    echo "  $f"
  done
else
  echo "No user log files found in $user_logdir to copy."
fi

# Always print a summary of the log directory location
echo "-----------------------------------------"
if [[ "$logpath" = /* ]]; then
  effective_logdir="$logpath"
else
  effective_logdir="$scripts_path/$logpath"
fi
echo "All process logs are located in: $effective_logdir"
echo "Review these logs for troubleshooting and details about each step."


# Remove dirty marker file at the end
rm -f "$DIRTY_MARKER"

if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}Process completed successfully with no errors.${NC}"
  exit 0
else
  echo -e "${RED}Process completed with $ERRORS error(s):${NC}"
  echo -e "${RED}$ERROR_LOG${NC}"
  echo -e "${RED}Please check the logs in the log directory for more details.${NC}"
  exit 1
fi