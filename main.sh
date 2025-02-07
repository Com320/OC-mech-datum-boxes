#!/bin/bash
# This script drives the overall install process.
# It installs dependencies, builds Bitcoin Knots, and builds Datum Gateway.
# Run this script from the project's root directory.

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

echo "Building Datum Gateway..."
"$SCRIPT_DIR/build-datum.sh"
if [ $? -eq 0 ]; then
    echo "Datum Gateway built successfully."
else
    echo "Datum Gateway build failed. Exiting."
    exit 1
fi

echo "Generating Bitcoin configuration..."
"$SCRIPT_DIR/bitcoin-conf-generator.sh"
if [ $? -eq 0 ]; then
    echo "Bitcoin configuration generated successfully."
else
    echo "Bitcoin configuration generation failed. Exiting."
    exit 1
fi

echo "Generating Bitcoin service..."
"$SCRIPT_DIR/generate-bitcoin-service.sh"
if [ $? -eq 0 ]; then
    echo "Bitcoin service generated successfully."
else
    echo "Bitcoin service generation failed. Exiting."
    exit 1
fi

echo "Generating Datum service..."
"$SCRIPT_DIR/generate-datum-service.sh"
if [ $? -eq 0 ]; then
    echo "Datum service generated successfully."
else
    echo "Datum service generation failed. Exiting."
    exit 1
fi

echo "Process completed successfully."