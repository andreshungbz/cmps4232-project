#!/bin/bash

# Stop execution if script fails since bash continues executing even if a command fails by default.
# -e exits immediately if a command exits with a non-zero status.
# -u treats unset variables as an error and exits immediately.
# -o pipefail causes a pipeline to return the exit status of the first command that fails.
set -euo pipefail

# VARIABLES

DIR=/srv
SHELL=/bin/bash

# FUNCTIONS

# log prints messages to stdout or stderr based on the log level.
log() {
  local level="$1"
  local message="$2"
  local color_reset="\033[0m"
  
  local color_code=""
  case "$level" in
    INFO) color_code="\033[0;34m";; # Blue
    WARN) color_code="\033[0;33m";; # Yellow
    ERROR) color_code="\033[0;31m";; # Red
    *) color_code="\033[0m";;
  esac

  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    # Redirect error messages to stderr.
    echo -e "[CMPS4232 Project] [${color_code}${level}${color_reset}] ${message}" >&2
  else
    echo -e "[CMPS4232 Project] [${color_code}${level}${color_reset}] ${message}"
  fi
}

# create_user creates a new user or updates the specified user if it already exists.
# --gid or -g specifies the primary group for the user.
# --groups or -G specifies the secondary groups for the user.
create_user() {
  local username="$1"
  local primary_group="$2"
  local secondary_groups="${3:-}"
  
  if id "$username" &>/dev/null; then
    log "INFO" "User '$username' already exists. Updating primary and secondary groups..."
    usermod --shell "$SHELL" --gid "$primary_group" "$username"
    if [[ -n "$secondary_groups" ]]; then
      # --append or -a so that existing secondary groups are not removed when adding new ones.
      usermod --append --groups "$secondary_groups" "$username"
    fi
  else
    log "INFO" "Creating user '$username'..."
    if [[ -n "$secondary_groups" ]]; then
      useradd --create-home --shell "$SHELL" --gid "$primary_group" --groups "$secondary_groups" "$username"
    else
      useradd --create-home --shell "$SHELL" --gid "$primary_group" "$username"
    fi
  fi
}

# MAIN SCRIPT

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

# Provision user accounts and assign primary and secondary groups.
log "INFO" "Creating user accounts..."
create_user matt sysadmins "developers,auditors"
create_user alice developers
create_user ben auditors "developers"

# Create shared directories for each group.
log "INFO" "Creating shared directories..."
mkdir --parents "$DIR/sysadmins" "$DIR/developers" "$DIR/auditors"

# Apply directory ownership and file permission bits.
# 2770 maps to rwxrwx---, giving group members read and write access.
# A Set Group ID (SGID) bit of 2 ensures new files created in the directory inherit directory group ownership.
# Unauthorized users are completely restricted.
for group in sysadmins developers auditors; do
  target_dir="$DIR/$group"
  chown root:"$group" "$target_dir"
  chmod 2770 "$target_dir"
done
