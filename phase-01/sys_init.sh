#!/bin/bash

# ====================================================================================
# sys_init.sh - Interactively provision a project user.
# Requires root privileges.
# ====================================================================================

# -e exits immediately if a command exits with a non-zero status.
# -u treats unset variables as an error and exits immediately.
# -o pipefail causes a pipeline to return the exit status of the first command that fails.
set -euo pipefail

# ====================================================================================
# VARIABLES
# ====================================================================================

LOG_FILE="/var/log/sys_init.log"

# ====================================================================================
# FUNCTIONS
# ====================================================================================

# log prints messages and writes them to a log file.
log() {
    local level="$1"
    local message="$2"
    local timestamp
    local color_code=""
    local color_reset=$'\033[0m'
    local ending=$'\n'

    # Use English month names (LC_ALL) and Belize time zone (TZ).
    timestamp=$(LC_ALL=C TZ="America/Belize" date '+%d %b %Y, %I:%M:%S %p %Z')

    # Write log to file.
    printf '[%s] [%s] %s\n' \
        "$timestamp" "$level" "$message" >> "$LOG_FILE"

    # Choose color code based on log level.
    case "$level" in
        INFO)  color_code=$'\033[0;34m' ;; # Blue
        USER)  color_code=$'\033[0;35m' ;; # Purple
        WARN)  color_code=$'\033[0;33m' ;; # Yellow
        ERROR) color_code=$'\033[0;31m' ;; # Red
        *)     color_code="$color_reset" ;;
    esac

    # Prompt mode ends with a space instead of a newline on screen.
    if [[ "${3:-}" == "prompt" ]]; then
        ending=" "
    fi

    # Print log to stdout, sending warnings and errors to stderr instead.
    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
        printf '[%s%s%s] %s%s' \
            "$color_code" "$level" "$color_reset" "$message" "$ending" >&2
    else
        printf '[%s%s%s] %s%s' \
            "$color_code" "$level" "$color_reset" "$message" "$ending"
    fi
}

# prompt_user_details collects and validates the new account's username, primary group, and optional secondary groups.
prompt_user_details() {
    # Username Prompt
    while true; do
        log "USER" "Enter a new username:" prompt
        if ! IFS= read -r username; then # Preserve input literally by resetting the input-field separator (IFS).
            printf '\n'
            log "ERROR" "Input ended before a username was supplied."
            exit 1
        fi

        # Check username policy: 1-32 characters, starting with a lowercase letter.
        # Remaining characters may be lowercase letters, digits, _ or -.
        if [[ ! "$username" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
            log "WARN" "Use 1-32 characters: only lowercase letters, digits, _ or -."
            continue
        fi

        # Check if the username is already in use.
        if getent passwd "$username" > /dev/null; then
            log "WARN" "That username already exists. Choose another."
            continue
        fi

        # Check if the home directory or symbolic link for the username already exists.
        if [[ -e "/home/$username" || -L "/home/$username" ]]; then
            log "WARN" "That home path already exists. Choose another username."
            continue
        fi

        break
    done

    # Primary Group Prompt
    while true; do
        log "USER" "Enter the primary group (sysadmins, developers, or auditors):" prompt
        if ! IFS= read -r primary_group; then
            printf '\n'
            log "ERROR" "Input ended before a primary group was supplied."
            exit 1
        fi

        case "$primary_group" in
            sysadmins|developers|auditors)
                # Check if the selected group exists in the system.
                if getent group "$primary_group" > /dev/null; then
                    break
                else
                    log "ERROR" "The selected project group is missing."
                    exit 1
                fi
                ;;
            *)
                log "WARN" "Choose either sysadmins, developers, or auditors."
                ;;
        esac
    done

    # Secondary Group Prompt
    while true; do
        log "USER" "Enter secondary groups as a comma-separated list (optional):" prompt
        if ! IFS= read -r secondary_groups_input; then
            printf '\n'
            log "ERROR" "Input ended before secondary groups were supplied."
            exit 1
        fi

        # Remove all whitespace from the input.
        secondary_groups="${secondary_groups_input//[[:space:]]/}"

        if [[ -z "$secondary_groups" ]]; then
            secondary_groups=""
            break
        fi

        # Validate the secondary groups.
        IFS=',' read -ra group_list <<< "$secondary_groups" # Split groups into an array.
        valid_secondary_groups=true
        for group_name in "${group_list[@]}"; do
            # Check for input cases like "developers,,auditors" or "developers,"
            if [[ -z "$group_name" ]]; then
                valid_secondary_groups=false
                break
            fi

            # Check if the group exists in the system.
            if ! getent group "$group_name" > /dev/null; then
                log "WARN" "Secondary group '$group_name' does not exist. Enter valid group names separated by commas."
                valid_secondary_groups=false
                break
            fi
        done

        if [[ "$valid_secondary_groups" == true ]]; then
            break
        fi
    done
}

# validate_password checks if a password meets the required criteria.
validate_password() {
    # Use the C locale to ensure consistent character class behavior across different environments.
    local LC_ALL=C

    [[ "$1" =~ ^.{8,}$ && # At least 8 characters
       "$1" =~ [A-Z] && # One uppercase letter
       "$1" =~ [a-z] && # One lowercase letter
       "$1" =~ [0-9] && # One digit
       "$1" =~ [[:punct:]] ]] # One special character
}

# prompt_password reads for the initial password without displaying or logging its contents.
prompt_password() {
    # Initial Password Prompt
    local confirmation
    while true; do
        log "USER" "Enter an initial password:" prompt
        if ! IFS= read -r -s password; then
            printf '\n'
            unset password
            log "ERROR" "Input ended before a password was supplied."
            exit 1
        fi
        printf '\n'

        # Check if the password meets the required criteria.
        if ! validate_password "$password"; then
            unset password
            log "WARN" "Password must have at least 8 characters with uppercase, lowercase, a digit, and a special character. Try again."
            continue
        fi

        # Confirmation Prompt
        log "USER" "Enter the password again to confirm:" prompt
        if ! IFS= read -r -s confirmation; then
            printf '\n'
            unset password confirmation
            log "ERROR" "Input ended before password confirmation."
            exit 1
        fi
        printf '\n'

        # Check if the password and confirmation match.
        if [[ "$password" != "$confirmation" ]]; then
            unset password confirmation
            log "WARN" "Passwords do not match. Try again."
            continue
        fi

        unset confirmation
        log "INFO" "Password validation and confirmation succeeded."
        break
    done
}

# run_logged is a wrapper that runs a command, separately logging stdout and stderr.
run_logged() {
    local description="$1"
    local status=0
    local line

    log "INFO" "$description"

    # Run command as passed, capturing stdout and stderr in separate files.
    shift # Shift the description off the argument list, leaving the command and its arguments.
    if "$@" > "$LOG_WORK_DIR/stdout" 2> "$LOG_WORK_DIR/stderr"; then
        status=0
    else
        status=$?
    fi

    # Log every line, including a final line without a newline.
    while IFS= read -r line || [[ -n "$line" ]]; do
        log "INFO" "[STDOUT] $line"
    done < "$LOG_WORK_DIR/stdout"

    while IFS= read -r line || [[ -n "$line" ]]; do
        log "ERROR" "[STDERR] $line"
    done < "$LOG_WORK_DIR/stderr"

    # Log an error if the command failed.
    if [[ "$status" -ne 0 ]]; then
        log "ERROR" "$description failed (exit status $status)."
    fi

    return "$status"
}

# create_account makes the account and configures its initial password.
create_account() {
    # Create the account with the home directory, shell, primary group, and optional secondary groups. It is initially disabled.
    if [[ -n "$secondary_groups" ]]; then
        if ! run_logged "Creating account '$username'." \
            useradd -m -d "/home/$username" \
            -s /bin/bash -g "$primary_group" -G "$secondary_groups" \
            -e 1970-01-02 "$username"
        then
            unset password
            log "ERROR" "Account creation failed. Inspect the log before retrying."
            exit 1
        fi
    else
        if ! run_logged "Creating account '$username'." \
            useradd -m -d "/home/$username" \
            -s /bin/bash -g "$primary_group" \
            -e 1970-01-02 "$username"
        then
            unset password
            log "ERROR" "Account creation failed. Inspect the log before retrying."
            exit 1
        fi
    fi

    # Set the account's initial password through stdin without logging its value.
    if ! printf '%s:%s\n' "$username" "$password" |
        run_logged "Setting the initial password." chpasswd
    then
        unset password
        log "ERROR" "Password assignment failed. The account remains disabled."
        exit 1
    fi

    # Prevent accidental exposure of the password after setting it for the account.
    unset password

    # Set the account to require a password change at first login.
    if ! run_logged "Requiring a password change at first login." \
        chage -d 0 "$username"
    then
        log "ERROR" "Password aging failed. The account remains disabled."
        exit 1
    fi

    log "INFO" "Account '$username' created; shell setup and activation are pending."
}

# configure_shell appends custom aliases and prompt styling to the user's .bashrc profile.
configure_shell() {
    local bashrc="/home/$username/.bashrc"

    # Apply customized .bashrc template.
    if ! run_logged "Adding aliases and prompt styling." \
        bash -c 'cat >> "$1"' _ "$bashrc" <<'BASHRC'

# [CMPS4232 Project] Phase 1: Custom Aliases and Prompt.

# List all files with details and file-type indicators.
alias ll='ls -alF'

# List files, including hidden ones, except '.' and '..'.
alias la='ls -A'

# Clear the terminal display.
alias c='clear'

# Show the username in yellow, @ in white, hostname in blue, and path in green.
PS1='\[\e[33m\]\u\[\e[37m\]@\[\e[34m\]\h\[\e[0m\]:\[\e[32m\]\w\[\e[0m\]\$ '
BASHRC
    then
        log "ERROR" "Shell customization failed. The account remains disabled."
        exit 1
    fi

    # Set .bashrc ownership.
    if ! run_logged "Setting .bashrc ownership." \
        chown "$username:$primary_group" "$bashrc"
    then
        log "ERROR" "Ownership configuration failed. The account remains disabled."
        exit 1
    fi

    # Set .bashrc permissions.
    if ! run_logged "Setting .bashrc permissions." \
        chmod 644 "$bashrc"
    then
        log "ERROR" "Permission configuration failed. The account remains disabled."
        exit 1
    fi

    # Validate .bashrc syntax.
    if ! run_logged "Checking .bashrc syntax." bash -n "$bashrc"; then
        log "ERROR" "Shell syntax check failed. The account remains disabled."
        exit 1
    fi
}

# ====================================================================================
# SCRIPT START
# ====================================================================================

# If the effective user ID (EUID) is not 0 (root), exit.
if [[ "$EUID" -ne 0 ]]; then
    printf 'ERROR: Run this script with sudo.\n' >&2
    exit 1
fi

# Restrict newly created files to their owner for the duration of the script.
umask 077

# Create the log if needed, preserving previous entries.
if ! touch "$LOG_FILE" || ! chmod 600 "$LOG_FILE"; then
    printf 'ERROR: Cannot prepare the log file.\n' >&2
    exit 1
fi

# Create a private directory for temporary command-output files.
if ! LOG_WORK_DIR=$(mktemp -d /tmp/sys_init.XXXXXX); then
    log "ERROR" "Could not create the temporary logging directory."
    exit 1
fi

# Remove the temporary files and directory when the script exits.
trap 'rm -f -- "$LOG_WORK_DIR/stdout" "$LOG_WORK_DIR/stderr"; rmdir -- "$LOG_WORK_DIR"' EXIT

# Convert interruption signals into exits so EXIT cleanup runs.
trap 'exit 130' INT
trap 'exit 143' TERM

# Setup Steps
log "INFO" "sys_init.sh started."
prompt_user_details
prompt_password
create_account
configure_shell

# Remove account expiration after every setup step succeeds.
if ! run_logged "Activating account '$username' with primary group '$primary_group'." \
    chage -E -1 "$username"
then
    log "ERROR" "Activation failed. Inspect the log."
    exit 1
fi

log "INFO" "Provisioning completed successfully for '$username'."
log "INFO" "A password change is required at first login."
