#!/bin/bash

# ====================================================================================
# setup.sh - Sets up the groups and shared directory configuration.
# Requires root privileges.
# ====================================================================================

# -e exits immediately if a command exits with a non-zero status.
# -u treats unset variables as an error and exits immediately.
# -o pipefail causes a pipeline to return the exit status of the first command that fails.
set -euo pipefail

# ====================================================================================
# VARIABLES
# ====================================================================================

DIR=/srv
SHELL=/bin/bash

# ====================================================================================
# FUNCTIONS
# ====================================================================================

# log prints messages based on the log level.
log() {
    local level="$1"
    local message="$2"
    local color_code=""
    local color_reset="\033[0m"

    # Choose color code based on log level.
    case "$level" in
        INFO) color_code="\033[0;34m";; # Blue
        WARN) color_code="\033[0;33m";; # Yellow
        ERROR) color_code="\033[0;31m";; # Red
        *) color_code="\033[0m";;
    esac

    # Print log to stdout, sending warnings and errors to stderr instead.
    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
        echo -e "[CMPS4232 Project] [${color_code}${level}${color_reset}] ${message}" >&2
    else
        echo -e "[CMPS4232 Project] [${color_code}${level}${color_reset}] ${message}"
    fi
}

# ====================================================================================
# SCRIPT START
# ====================================================================================

# If the effective user ID (EUID) is not 0 (root), exit.
if [[ $EUID -ne 0 ]]; then
    log "ERROR" "Script must be run as root or via sudo."
    exit 1
fi

# Create secondary groups.
# --force or -f prevents errors if the group already exists.
log "INFO" "Creating secondary groups..."
groupadd --force sysadmins
groupadd --force developers
groupadd --force auditors

# Create shared directories for each group.
log "INFO" "Creating shared directories..."
mkdir --parents "$DIR/sysadmins" "$DIR/developers" "$DIR/auditors"

# Apply directory ownership and file permission bits.
# 2770 maps to drwxrws---, giving group members read and write access.
# A Set Group ID (SGID) bit of 2 (rws) ensures new files created in the directory inherit directory group ownership.
# Unauthorized users are completely restricted.
for group in sysadmins developers auditors; do
    target_dir="$DIR/$group"
    chown root:"$group" "$target_dir"
    chmod 2770 "$target_dir"
done
