#!/bin/bash
# This script verifies a git tag signature
# Arguments:
# $1 - Repository path
# $2 - Tag name to verify
# $3 - Expected key fingerprint
# $4 - Log file path (optional)

# Source common utilities
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/utils.sh"

# Initialize logging
init_logging "verify-git-tag"

# Exit on any error
set -e

REPO_PATH="$1"
TAG="$2"
FINGERPRINT="$3"
CUSTOM_LOG_FILE="$4"

if [ -z "$REPO_PATH" ] || [ -z "$TAG" ] || [ -z "$FINGERPRINT" ]; then
    log_display "${RED}Error: Missing required parameters${NC}"
    log_display "Usage: $0 <repository_path> <tag> <key_fingerprint> [log_file]"
    exit 1
fi

# Check if we can access the repository
cd "$REPO_PATH" || { log_display "${RED}Error: Cannot change to repository directory $REPO_PATH${NC}"; exit 1; }

# Import the key if it's not already in the keyring
if ! gpg --list-keys "$FINGERPRINT" &> /dev/null; then
    log_display "Importing key with fingerprint: $FINGERPRINT"
    import_output=$(gpg --keyserver keyserver.ubuntu.com --recv-keys "$FINGERPRINT" 2>&1)
    if [ $? -ne 0 ]; then
        log_display "${YELLOW}Failed to import key from Ubuntu keyserver, trying keys.openpgp.org...${NC}"
        log "Import output: $import_output"
        import_output=$(gpg --keyserver keys.openpgp.org --recv-keys "$FINGERPRINT" 2>&1)
        if [ $? -ne 0 ]; then
            log_display "${RED}Error: Failed to import key from both keyservers${NC}"
            log "Import output: $import_output"
            exit 1
        fi
    fi
    log "Key import output: $import_output"
fi

# First make sure the tag exists
tag_list_output=$(git tag -l 2>&1)
log "Available tags: $tag_list_output"
if ! echo "$tag_list_output" | grep -q "^$TAG$"; then
    log "Error: Tag $TAG does not exist in the repository"
    exit 1
fi

# Verify the tag using Git's built-in verification
log "Verifying signature for tag: $TAG"

# Capture the output of git verify-tag
verification_output=$(git verify-tag "$TAG" 2>&1)
verification_result=$?

# Log the entire verification output
log "=== Git Verification Output Start ==="
echo "$verification_output" | while IFS= read -r line; do
    log "$line"
done
log "=== Git Verification Output End ==="

# Check the verification result
if [ $verification_result -eq 0 ]; then
    log "Signature verification successful for tag: $TAG"
    exit 0
else
    log "Error: Tag signature verification failed"
    exit 1
fi