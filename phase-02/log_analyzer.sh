#!/bin/bash

# ====================================================================================
# log_analyzer.sh - Analyze authentication events and report current memory usage.
# Reads all entries currently in auth.log; replaces the report after a successful run.
# Requires root privileges.
# ====================================================================================

# Exit on unhandled failures, unset variables, or failures within pipelines.
set -euo pipefail

# ====================================================================================
# VARIABLES
# ====================================================================================

AUTH_LOG="/var/log/auth.log"
REPORT_FILE="/var/log/audit_report.txt"
TOP_COUNT=10
WORK_DIR=""

# Use stable English log patterns, decimal formatting, and Belize report timestamps.
export LC_ALL=C
export TZ="America/Belize"
# Provide a dependable command search path for cron.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ====================================================================================
# FUNCTIONS
# ====================================================================================

# log keeps operational messages separate from the plain-text audit report.
log() {
    local level="$1"
    local message="$2"
    local timestamp
    local color_code=""
    local color_reset=""
    local output_fd=1
    timestamp=$(date '+%d %b %Y, %I:%M:%S %p %Z')

    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
        output_fd=2
    fi

    # Match sys_init.sh colors on screen; keep redirected/cron output plain.
    if [[ -t "$output_fd" ]]; then
        color_reset=$'\033[0m'
        case "$level" in
            INFO)  color_code=$'\033[0;34m' ;; # Blue
            WARN)  color_code=$'\033[0;33m' ;; # Yellow
            ERROR) color_code=$'\033[0;31m' ;; # Red
        esac
    fi

    printf '[%s] [%s%s%s] %s\n' \
        "$timestamp" "$color_code" "$level" "$color_reset" "$message" >&"$output_fd"
}

# usage describes optional paths for testing with a separate sample log.
usage() {
    printf '%s\n' \
        'Usage: bash log_analyzer.sh [--input FILE] [--output FILE] [--top NUMBER]' \
        'Defaults: /var/log/auth.log, /var/log/audit_report.txt, top 10 processes.' \
        'Requires permission to read the input and write in the output directory.' \
        'Analyzes the entire current input file, including all users.'
}

# parse_arguments accepts explicit settings without interactive prompts.
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --input|--output|--top)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    log "ERROR" "Option '$1' requires a value."
                    return 1
                fi
                case "$1" in
                    --input) AUTH_LOG="$2" ;;
                    --output) REPORT_FILE="$2" ;;
                    --top) TOP_COUNT="$2" ;;
                esac
                shift 2
                ;;
            --help|-h) usage; exit 0 ;;
            *) log "ERROR" "Unknown option: $1"; usage >&2; return 1 ;;
        esac
    done

    if [[ ! "$TOP_COUNT" =~ ^[1-9][0-9]{0,3}$ ]]; then
        log "ERROR" "The process count must be an integer from 1 to 9999."
        return 1
    fi
}

# cleanup removes only this run's private temporary files.
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

# validate_environment checks dependencies, input access, and report destination.
validate_environment() {
    local command_name
    for command_name in awk ps date dirname basename mktemp chmod cat mv rm; do
        if ! command -v "$command_name" > /dev/null; then
            log "ERROR" "Required command '$command_name' is unavailable."
            return 1
        fi
    done

    if [[ ! -f "$AUTH_LOG" || ! -r "$AUTH_LOG" ]]; then
        log "ERROR" "Cannot read authentication log '$AUTH_LOG'. Check its path and permissions."
        return 1
    fi

    # Resolve parent paths so the report cannot accidentally replace its input.
    AUTH_LOG="$(cd -- "$(dirname -- "$AUTH_LOG")" && pwd -P)/$(basename -- "$AUTH_LOG")"
    REPORT_DIR=$(cd -- "$(dirname -- "$REPORT_FILE")" && pwd -P) || {
        log "ERROR" "The report directory does not exist or cannot be accessed."
        return 1
    }
    REPORT_FILE="$REPORT_DIR/$(basename -- "$REPORT_FILE")"

    if [[ ! -w "$REPORT_DIR" || ! -x "$REPORT_DIR" ]]; then
        log "ERROR" "Cannot write in '$REPORT_DIR'. Run with appropriate permissions."
        return 1
    fi
    if [[ -L "$REPORT_FILE" || ( -e "$REPORT_FILE" && ! -f "$REPORT_FILE" ) ]]; then
        log "ERROR" "The report destination must be a regular file, not a link or directory."
        return 1
    fi
    if [[ "$AUTH_LOG" == "$REPORT_FILE" || "$AUTH_LOG" -ef "$REPORT_FILE" ]]; then
        log "ERROR" "The report destination must differ from the authentication log."
        return 1
    fi
}

# analyze_authentication scans the log once and spools matches to three files.
# Counts represent matching records, not unique attempts, commands, or sessions.
analyze_authentication() {
    : > "$WORK_DIR/ssh"
    : > "$WORK_DIR/sudo"
    : > "$WORK_DIR/root"

    awk -v work_dir="$WORK_DIR" '
        BEGIN {
            # Accept traditional syslog and ISO-style rsyslog timestamps.
            timestamp = "((Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[[:space:]]+[0-9]+[[:space:]]+[0-9:]+|[0-9][0-9][0-9][0-9]-[^[:space:]]+)"
            prefix = "^" timestamp "[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]:]+:[[:space:]]*"
        }
        {
            total++
            if (!match($0, prefix)) {
                if ($0 !~ /^[[:space:]]*$/) malformed++
                next
            }

            message = substr($0, RLENGTH + 1)
            header = substr($0, 1, RLENGTH)
            sub(/:[[:space:]]*$/, "", header)
            sub(/^.*[[:space:]]/, "", header)
            program = header
            sub(/\[[0-9]+\]$/, "", program)

            # Explicit SSH failure messages; do not count mere invalid-user notices.
            if (program ~ /^sshd(-session|-auth)?$/ &&
                (message ~ /^Failed (password|publickey|keyboard-interactive(\/pam)?|none) for .+ from [^[:space:]]+ port [0-9]+/ ||
                 message ~ /^error: PAM: Authentication failure for / ||
                 message ~ /^pam_unix\(sshd:auth\): authentication failure([;[:space:]]|$)/)) {
                print $0 > (work_dir "/ssh")
                ssh_count++
            }

            # Authorization denials are distinct from incorrect sudo passwords.
            if (program == "sudo" &&
                message ~ /^[^[:space:]:]+[[:space:]]*:[[:space:]]*(user NOT in sudoers|user NOT authorized on host|command not allowed|sorry, you are not allowed to)[[:space:];]/) {
                print $0 > (work_dir "/sudo")
                sudo_count++
            }

            # A root session opening proves access was granted. USER=root in a
            # command request alone is insufficient. Exclude root-to-root sessions.
            if (program ~ /^(sudo|su|su-l)$/ &&
                message ~ /^pam_unix\((sudo|sudo-i|su|su-l):session\): session opened for user root(\(uid=0\))? by /) {
                initiator = message
                sub(/^.* by /, "", initiator)
                if (match(initiator, /\(uid=[0-9]+\)/)) {
                    uid_text = substr(initiator, RSTART + 5, RLENGTH - 6)
                    if (uid_text + 0 != 0) {
                        print $0 > (work_dir "/root")
                        root_count++
                    }
                }
            }
        }
        END {
            printf "%d %d %d %d %d\n", total, malformed, ssh_count, sudo_count, root_count > (work_dir "/counts")
        }
    ' "$AUTH_LOG"
}

# collect_processes gets one Ubuntu procps snapshot, sorted by resident memory.
collect_processes() {
    PROCESS_TIMESTAMP=$(date '+%d %b %Y, %I:%M:%S %p %Z')
    # Consume all ps output instead of exiting early, avoiding SIGPIPE under pipefail.
    if ! ps -eo pid=,user:32=,pmem=,rss=,comm= --sort=-rss |
        awk -v limit="$TOP_COUNT" '
            BEGIN { printf "%-8s %-32s %8s %14s %s\n", "PID", "USER", "MEM (%)", "RSS (KiB)", "COMMAND" }
            NF >= 5 && $1 ~ /^[0-9]+$/ {
                if (++seen <= limit) {
                    # Keep command names containing spaces, while formatting
                    # every row with the same column widths as the headings.
                    command = $0
                    sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", command)
                    printf "%-8s %-32s %8s %14s %s\n", $1, $2, $3, $4, command
                }
            }
            END { if (seen == 0) exit 1 }
        ' > "$WORK_DIR/processes"
    then
        log "ERROR" "Could not obtain process metrics. This script requires Ubuntu/Linux procps ps."
        return 1
    fi
}

# write_event_section preserves source entries so each count can be checked.
write_event_section() {
    local title="$1"
    local count="$2"
    local matches="$3"
    printf '\n%s\nMatching records: %s\n' "$title" "$count"
    if [[ "$count" -eq 0 ]]; then
        printf 'No matching events found.\n'
    else
        cat -- "$matches"
    fi
}

# write_report assembles the complete plain-text report before publishing it.
write_report() {
    local total malformed ssh_count sudo_count root_count
    read -r total malformed ssh_count sudo_count root_count < "$WORK_DIR/counts"

    {
        printf 'SYSTEM AUTHENTICATION AUDIT REPORT\n'
        printf 'Generated: %s\n' "$(date '+%d %b %Y, %I:%M:%S %p %Z')"
        printf 'Source: %s\n' "$AUTH_LOG"
        printf 'Scope: All entries read from the current source file; all users.\n'
        printf 'No last-24-hours filter; rotated logs are excluded.\n'
        printf 'Records read: %s\nUnrecognized nonblank record formats: %s\n' "$total" "$malformed"
        printf 'Counts describe matching log records, not unique attempts.\n'
        printf 'Authentication failures and policy denials are classified separately.\n'

        write_event_section '1. FAILED SSH LOGIN ATTEMPTS' "$ssh_count" "$WORK_DIR/ssh"
        write_event_section '2. UNAUTHORIZED SUDO ATTEMPTS' "$sudo_count" "$WORK_DIR/sudo"
        write_event_section '3. SUCCESSFUL ESCALATIONS TO ROOT' "$root_count" "$WORK_DIR/root"
        printf 'Root detection: sudo/su PAM session openings with a nonzero initiating UID.\n'
        printf 'Direct root logins and root-to-root sessions are excluded.\n'

        printf '\n4. TOP %s PROCESSES BY RESIDENT MEMORY\n' "$TOP_COUNT"
        printf 'Snapshot: %s\n' "$PROCESS_TIMESTAMP"
        printf 'RSS is resident memory in KiB; MEM is the percentage of physical memory.\n'
        printf 'This is a current snapshot, not historical usage or unique shared-memory accounting.\n'
        cat -- "$WORK_DIR/processes"
    } > "$WORK_DIR/report"

    chmod 600 "$WORK_DIR/report"
    # The temporary directory is on the same filesystem as the destination.
    mv -fT -- "$WORK_DIR/report" "$REPORT_FILE"
}

# main keeps the script noninteractive so the same command can run from cron.
main() {
    parse_arguments "$@"
    validate_environment
    umask 077
    WORK_DIR=$(mktemp -d "$REPORT_DIR/.log_analyzer.XXXXXX")
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'log "ERROR" "Audit generation failed; the previous report has been preserved."' ERR

    log "INFO" "Analyzing '$AUTH_LOG'."
    analyze_authentication
    collect_processes
    write_report
    log "INFO" "Audit report saved to '$REPORT_FILE'."
}

# ====================================================================================
# SCRIPT START
# ====================================================================================

# Inherit ERR handling in functions so command failures are reported clearly.
set -E
main "$@"

