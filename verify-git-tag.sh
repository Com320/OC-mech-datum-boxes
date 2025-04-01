#!/bin/bash
# This script verifies a git tag signature
# Arguments:
# $1 - Repository path
# $2 - Tag name to verify
# $3 - Expected key fingerprint
# $4 - Log file path (optional)

# Exit on any error
set -e

REPO_PATH="$1"
TAG="$2"
FINGERPRINT="$3"
LOG_FILE="$4"

# Function to log messages to file and console
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
    if [ -n "$LOG_FILE" ] && [ -w "$(dirname "$LOG_FILE")" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"
    fi
}

if [ -z "$REPO_PATH" ] || [ -z "$TAG" ] || [ -z "$FINGERPRINT" ]; then
    log "Error: Missing required parameters"
    log "Usage: $0 <repository_path> <tag> <key_fingerprint> [log_file]"
    exit 1
fi

# Check if we can access the repository
cd "$REPO_PATH" || { log "Error: Cannot change to repository directory $REPO_PATH"; exit 1; }

# Import the key if it's not already in the keyring
if ! gpg --list-keys "$FINGERPRINT" &> /dev/null; then
    log "Importing key with fingerprint: $FINGERPRINT"
    if ! gpg --keyserver keyserver.ubuntu.com --recv-keys "$FINGERPRINT" 2>&1; then
        log "Failed to import key from Ubuntu keyserver, trying keys.openpgp.org..."
        if ! gpg --keyserver keys.openpgp.org --recv-keys "$FINGERPRINT" 2>&1; then
            log "Error: Failed to import key from both keyservers"
            exit 1
        fi
    fi
fi

# First make sure the tag exists
if ! git tag -l | grep -q "^$TAG$"; then
    log "Error: Tag $TAG does not exist in the repository"
    exit 1
fi

# Verify the tag using Git's built-in verification
log "Verifying signature for tag: $TAG"
if git verify-tag "$TAG" 2>&1; then
    log "Signature verification successful for tag: $TAG"
    exit 0
else
    log "Error: Tag signature verification failed"
    exit 1
fi