#!/bin/bash

# Log file location
LOGFILE="$HOME/brew-update.log"

# ANSI color codes
GREEN='\033[0;32m'
YELLOW='\033[38;5;208m'
RED='\033[0;31m'
NC='\033[0m' # No color / reset

# Function to print bordered messages
print_message() {
    local COLOR=$1
    local MESSAGE=$2
    echo -e "${COLOR}######################################${NC}"
    echo -e "${COLOR}### ${MESSAGE}${NC}"
    echo -e "${COLOR}######################################${NC}"
}

# Starting Homebrew update process
print_message "${YELLOW}" "Starting to update Homebrew..." | tee -a "$LOGFILE"

# Update Homebrew
if brew update 2>&1 | tee -a "$LOGFILE"; then
    print_message "${GREEN}" "Homebrew update successful." | tee -a "$LOGFILE"
else
    print_message "${RED}" "Error updating Homebrew. Check the log for details: $LOGFILE"
    exit 1
fi


# Run  Homebrew Doctor process
print_message "${YELLOW}" "Starting to Homebrew Doctor..." | tee -a "$LOGFILE"

# Update Homebrew
if brew doctor 2>&1 | tee -a "$LOGFILE"; then
    print_message "${GREEN}" "Homebrew doctor successful." | tee -a "$LOGFILE"
else
    print_message "${RED}" "Error usign doctor in Homebrew. Check the log for details: $LOGFILE"
    exit 1
fi


# Upgrade installed packages
print_message "${YELLOW}" "Upgrading installed packages..." | tee -a "$LOGFILE"
if brew upgrade 2>&1 | tee -a "$LOGFILE"; then
    print_message "${GREEN}" "Upgrade successful." | tee -a "$LOGFILE"
else
    print_message "${RED}" "Error upgrading packages. Check the log for details: $LOGFILE"
    exit 1
fi

# Cleanup outdated versions
print_message "${YELLOW}" "Running cleanup..." | tee -a "$LOGFILE"
if brew cleanup 2>&1 | tee -a "$LOGFILE"; then
    print_message "${GREEN}" "Cleanup successful." | tee -a "$LOGFILE"
else
    print_message "${RED}" "Error during cleanup. Check the log for details: $LOGFILE"
    exit 1
fi

# Completion message
print_message "${GREEN}" "Homebrew update and maintenance completed!" | tee -a "$LOGFILE"