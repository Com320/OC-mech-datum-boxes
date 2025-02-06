#!/bin/bash
# This script drives the overall install process.
# It installs dependencies, builds Bitcoin Knots, and performs other setup tasks.

SCRIPT_DIR="$(dirname "$0")"

echo "Installing dependencies..."
"$SCRIPT_DIR/dependencies.sh"
if [ $? -eq 0 ]; then
    echo "Dependencies installed successfully."
else
    echo "Dependency installation failed. Exiting."
    exit 1
fi

echo "Building Bitcoin Knots..."
"$SCRIPT_DIR/build-btcknots.sh"
if [ $? -eq 0 ]; then
    echo "Bitcoin Knots built successfully."
else
    echo "Bitcoin Knots build failed. Exiting."
    exit 1
fi

echo "Process completed successfully."