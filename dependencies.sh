#!/bin/bash

# Script to install specific dependencies using apt
# Run this script with sudo privileges

# List of packages to install
packages=(
    "git"
    "pkg-config"
    "cmake"
    "libmicrohttpd-dev"
    "libjansson-dev"
    "libcurl4-openssl-dev"
    "libsodium-dev"
    "psmisc"
)

# Update package lists
echo "Updating package lists..."
sudo apt-get update

# Install packages
echo "Installing packages..."
for package in "${packages[@]}"; do
    echo "Installing $package..."
    if sudo apt-get install -y "$package"; then
        echo "$package installed successfully."
    else
        echo "Failed to install $package."
    fi
done

echo "Installation process completed."
