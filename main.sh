#!/bin/bash
# This script drives the overall install process.
# It installs dependencies, builds Bitcoin Knots, and builds Datum Gateway.
# Run this script from the project's root directory.

SCRIPT_DIR="$(dirname "$0")"
ERRORS=0
ERROR_LOG=""

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to track errors
track_error() {
  local step=$1
  local ret_val=$2
  
  if [ $ret_val -ne 0 ]; then
    ERRORS=$((ERRORS+1))
    ERROR_LOG="${ERROR_LOG}\n- Error in ${step}"
    echo -e "${RED}${step} failed. Continuing with next step...${NC}"
    return 1
  fi
  echo -e "${GREEN}${step} completed successfully.${NC}"
  return 0
}

echo "Installing dependencies..."
"$SCRIPT_DIR/dependencies.sh"
track_error "Dependencies installation" $?

echo "Building Bitcoin Knots..."
"$SCRIPT_DIR/build-btcknots.sh"
track_error "Bitcoin Knots build" $?

echo "Building Datum Gateway..."
"$SCRIPT_DIR/build-datum.sh"
track_error "Datum Gateway build" $?

echo "Generating Bitcoin configuration..."
"$SCRIPT_DIR/bitcoin-conf-generator.sh"
track_error "Bitcoin configuration generation" $?

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