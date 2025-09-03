#!/bin/bash
# This script displays a welcome message for the Datum box setup.
# It provides information about the process and asks for user confirmation.
# Sourced by main.sh as part of the installation workflow.

log_display ""
log_display "${YELLOW}  Hi, thanks for running this automated deployment solution that'll turn your Debian machine into a full-fledged Datum box!${NC}"
log_display ""
log_display "${YELLOW}  If you need help or if this is the first time you're using this solution, you might find these instructions helpful:${NC}"
log_display "${YELLOW}  https://github.com/BitcoinMechanic/datum-setup-instructions${NC}"
log_display ""
if ! confirm_prompt "Do you want to proceed? (y/n): "; then
    log_display "Exiting as requested."
    exit 1
fi
log_display "Proceeding..."
