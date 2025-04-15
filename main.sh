#!/bin/bash
# This script drives the overall install process.
# It installs dependencies, builds Bitcoin Knots, and builds Datum Gateway.
# Run this script from the project's root directory.

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

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

# Ensure the script is run as root/sudo
if [ "$(id -u)" -ne 0 ]; then
  log_display "${RED}This script must be run as root or with sudo privileges.${NC}"
  exit 1
fi

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
if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}Process completed successfully with no errors.${NC}"
  exit 0
else
  echo -e "${RED}Process completed with $ERRORS error(s):${NC}"
  echo -e "${RED}$ERROR_LOG${NC}"
  echo -e "${RED}Please check the logs in the log directory for more details.${NC}"
  exit 1
fi