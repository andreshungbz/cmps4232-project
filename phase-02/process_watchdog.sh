#!/bin/bash

# ====================================================================================
# process_watchdog.sh - Monitor selected Ubuntu processes and control excessive usage.
# Example: sudo ./process_watchdog.sh --pids 1234,5678 --log ./watchdog.log 
# Run with sufficient permissions for the selected processes and log destination.
# ====================================================================================

# Exit on unhandled failures, unset variables, or failures within pipelines.
set -euo pipefail

# ====================================================================================
# VARIABLES
# ====================================================================================

# Process IDs must be explicitly supplied; the watchdog does not select all processes.
PID_INPUT=""

# Default thresholds are configurable choices for this project.
CPU_THRESHOLD=80
MEM_THRESHOLD=10
INTERVAL=5
BREACH_LIMIT=3
NICE_VALUE=10
TERM_GRACE=5

# Zero means keep monitoring until all selected processes finish or monitoring stops.
MAX_CYCLES=0
DRY_RUN=false
LOG_FILE="/var/log/process_watchdog.log"

export LC_ALL=C
export TZ="America/Belize"
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Arrays are indexed by numeric PID; each target has independent identity and state.
declare -a PIDS=()
declare -a ACTIVE START_TIMES OWNERS LAST_TICKS LAST_UPTIME STAGES BREACHES TERM_TIMES

# The watchdog and its ancestors must never become action targets.
declare -a PROTECTED

# ====================================================================================
# FUNCTIONS
# ====================================================================================

# log appends plain-text evidence and displays colored labels only on a terminal.
log() {
    local level="$1" message="$2" timestamp color_code="" color_reset="" output_fd=1
    timestamp=$(date '+%d %b %Y, %I:%M:%S %p %Z')
    # A failed log write stops execution before an unrecorded action can be taken.
    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" >> "$LOG_FILE"
    if [[ "$level" == WARN || "$level" == ERROR ]]; then output_fd=2; fi
    if [[ -t "$output_fd" ]]; then
        color_reset=$'\033[0m'
        case "$level" in
            INFO) color_code=$'\033[0;34m' ;;
            WARN) color_code=$'\033[0;33m' ;;
            ERROR) color_code=$'\033[0;31m' ;;
        esac
    fi
    printf '[%s] [%s%s%s] %s\n' \
        "$timestamp" "$color_code" "$level" "$color_reset" "$message" >&"$output_fd"
}

# usage explains settings without starting a monitoring run.
usage() {
    cat <<'HELP'
Usage: bash process_watchdog.sh --pids PID[,PID...] [options]
  --cpu NUMBER       CPU threshold; 100 means one fully used core (default: 80)
  --memory NUMBER    Resident memory as percent of system RAM (default: 10)
  --interval SECONDS Sampling interval, integer 1-3600 (default: 5)
  --breaches NUMBER  Consecutive excessive samples per action stage (default: 3)
  --nice NUMBER      Absolute nice value, integer 0-19 (default: 10)
  --grace SECONDS    Grace period after SIGTERM, integer 1-3600 (default: 5)
  --cycles NUMBER    Number of monitoring cycles; 0 means unlimited (default: 0)
  --log FILE         Append-only action/measurement log
  --dry-run          Simulate priority changes and signals; take no process actions
  --help             Show this help
Either CPU or memory strictly above its threshold counts as an excessive sample.
After sustained excess: renice, then SIGTERM, then SIGKILL after the grace period.
The baseline sample does not count toward --cycles. Signals target individual PIDs.
HELP
}

# option_error handles invalid arguments before a log file is available.
option_error() {
    printf 'ERROR: %s\n' "$1" >&2
    return 1
}

# parse_arguments validates all settings before any process action is possible.
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            --help|-h) usage; exit 0 ;;
            --pids|--cpu|--memory|--interval|--breaches|--nice|--grace|--cycles|--log)
                [[ "$#" -ge 2 && -n "$2" ]] || { option_error "Option '$1' requires a value."; return 1; }
                case "$1" in
                    --pids) PID_INPUT="$2" ;; --cpu) CPU_THRESHOLD="$2" ;;
                    --memory) MEM_THRESHOLD="$2" ;; --interval) INTERVAL="$2" ;;
                    --breaches) BREACH_LIMIT="$2" ;; --nice) NICE_VALUE="$2" ;;
                    --grace) TERM_GRACE="$2" ;; --cycles) MAX_CYCLES="$2" ;;
                    --log) LOG_FILE="$2" ;;
                esac
                shift 2
                ;;
            *) option_error "Unknown option: $1"; return 1 ;;
        esac
    done

    [[ "$PID_INPUT" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || {
        option_error 'Supply positive PIDs separated by single commas.'; return 1;
    }
    local value
    for value in "$CPU_THRESHOLD" "$MEM_THRESHOLD"; do
        [[ "$value" =~ ^[0-9]{1,6}([.][0-9]{1,3})?$ ]] || {
            option_error 'Thresholds must be positive numbers.'; return 1;
        }
    done
    awk -v cpu="$CPU_THRESHOLD" -v mem="$MEM_THRESHOLD" \
        'BEGIN { exit !(cpu > 0 && mem > 0 && mem <= 100) }' || {
        option_error 'CPU must be positive; memory must be greater than 0 and at most 100.'; return 1;
    }
    for value in "$INTERVAL" "$BREACH_LIMIT" "$TERM_GRACE"; do
        [[ "$value" =~ ^[1-9][0-9]{0,3}$ ]] && (( value <= 3600 )) || {
            option_error 'Interval, breach count, and grace must be integers from 1 to 3600.'; return 1;
        }
    done
    [[ "$NICE_VALUE" =~ ^(0|[1-9]|1[0-9])$ ]] || {
        option_error 'Nice value must be an integer from 0 to 19.'; return 1;
    }
    [[ "$MAX_CYCLES" =~ ^(0|[1-9][0-9]{0,5})$ ]] || {
        option_error 'Cycles must be an integer from 0 to 999999.'; return 1;
    }
    IFS=',' read -ra PIDS <<< "$PID_INPUT"
}

# validate_environment checks Linux interfaces, dependencies, and the log destination.
validate_environment() {
    local command_name key amount unit
    for command_name in awk date getconf renice sleep chmod; do
        command -v "$command_name" > /dev/null || {
            option_error "Required command '$command_name' is unavailable."; return 1;
        }
    done
    [[ -r /proc/uptime && -r /proc/meminfo && -r /proc/$$/stat ]] || {
        option_error 'This script requires Ubuntu/Linux /proc process statistics.'; return 1;
    }
    CLOCK_TICKS=$(getconf CLK_TCK)
    PAGE_SIZE=$(getconf PAGESIZE)
    TOTAL_MEMORY=0
    while read -r key amount unit; do
        if [[ "$key" == MemTotal: ]]; then TOTAL_MEMORY="$amount"; break; fi
    done < /proc/meminfo
    [[ "$CLOCK_TICKS" =~ ^[1-9][0-9]*$ && "$PAGE_SIZE" =~ ^[1-9][0-9]*$ && "$TOTAL_MEMORY" =~ ^[1-9][0-9]*$ ]] || {
        option_error 'Cannot determine clock ticks, page size, or total memory.'; return 1;
    }
    [[ ! -L "$LOG_FILE" && ( ! -e "$LOG_FILE" || -f "$LOG_FILE" ) ]] || {
        option_error 'The log destination must be a regular file, not a link or directory.'; return 1;
    }
    umask 077
    if ! { : >> "$LOG_FILE"; } || ! chmod 600 "$LOG_FILE"; then
        option_error "Cannot prepare log '$LOG_FILE'. Check the path and permissions."
        return 1
    fi
}

# read_process reads one PID's identity and metrics without launching ps per sample.
# /proc/PID/stat fields after the parenthesized command start with field 3 (state).
read_process() {
    local pid="$1" stat_line rest key real_uid effective_uid remainder
    local -a fields
    if ! { IFS= read -r stat_line < "/proc/$pid/stat"; } 2> /dev/null; then return 1; fi
    # Strip through the LAST closing parenthesis: command names can contain spaces/).
    rest="${stat_line##*) }"
    read -ra fields <<< "$rest"
    [[ "${#fields[@]}" -ge 22 ]] || return 1
    PROC_STATE="${fields[0]}"
    PROC_PARENT="${fields[1]}"
    PROC_START="${fields[19]}"
    PROC_NICE="${fields[16]}"
    PROC_RSS="${fields[21]}"
    [[ "${fields[11]}" =~ ^[0-9]+$ && "${fields[12]}" =~ ^[0-9]+$ &&
       "$PROC_START" =~ ^[0-9]+$ && "$PROC_PARENT" =~ ^[0-9]+$ &&
       "$PROC_NICE" =~ ^-?[0-9]+$ && "$PROC_RSS" =~ ^[0-9]+$ ]] || return 1
    PROC_TICKS=$(( fields[11] + fields[12] ))
    PROC_NAME="${stat_line#*(}"
    PROC_NAME="${PROC_NAME%) *}"
    PROC_NAME="${PROC_NAME//[[:cntrl:]]/?}"
    PROC_UID=""
    if [[ ! -r "/proc/$pid/status" ]]; then return 1; fi
    while read -r key real_uid effective_uid remainder; do
        if [[ "$key" == Uid: ]]; then PROC_UID="$effective_uid"; break; fi
    done < "/proc/$pid/status" 2> /dev/null
    [[ "$PROC_UID" =~ ^[0-9]+$ ]]
}

# protect_ancestors prevents actions on this watchdog and its parent shell/session.
protect_ancestors() {
    local ancestor="$$"
    PROTECTED[1]=1
    while [[ "$ancestor" -gt 1 ]]; do
        PROTECTED[$ancestor]=1
        read_process "$ancestor" || { log ERROR 'Cannot identify watchdog ancestors.'; return 1; }
        ancestor="$PROC_PARENT"
    done
}

# same_process rechecks start time AND owner before any priority/signal operation.
# These checks reduce PID-reuse risk; Bash cannot make checking and signaling atomic.
same_process() {
    local pid="$1"
    read_process "$pid" || return 1
    [[ "$PROC_START" == "${START_TIMES[$pid]}" && "$PROC_UID" == "${OWNERS[$pid]}" &&
       "$PROC_STATE" != Z && "$PROC_STATE" != X ]]
}

# initialize_targets validates every target and records a CPU baseline before acting.
initialize_targets() {
    local pid now remainder
    read -r now remainder < /proc/uptime
    for pid in "${PIDS[@]}"; do
        [[ -z "${PROTECTED[$pid]:-}" ]] || { log ERROR "PID $pid is protected."; return 1; }
        [[ -z "${ACTIVE[$pid]:-}" ]] || { log ERROR "Duplicate target PID $pid."; return 1; }
        read_process "$pid" || { log ERROR "Cannot inspect target PID $pid."; return 1; }
        [[ "$PROC_STATE" != Z && "$PROC_STATE" != X ]] || { log ERROR "PID $pid has already finished."; return 1; }
        if [[ "$EUID" -ne 0 && "$PROC_UID" != "$EUID" ]]; then
            log ERROR "PID $pid belongs to another user; use appropriate privileges."
            return 1
        fi
        ACTIVE[$pid]=1
        START_TIMES[$pid]="$PROC_START"
        OWNERS[$pid]="$PROC_UID"
        LAST_TICKS[$pid]="$PROC_TICKS"
        LAST_UPTIME[$pid]="$now"
        STAGES[$pid]=monitor
        BREACHES[$pid]=0
        log INFO "Tracking PID $pid ($PROC_NAME), UID $PROC_UID, start ticks $PROC_START."
    done
}

# drop_target stops tracking a process that ended, changed identity, or became unreadable.
drop_target() {
    local pid="$1"
    log INFO "PID $pid ended, changed identity/owner, or became unreadable; no further actions."
    ACTIVE[$pid]=0
}

# lower_priority makes one absolute priority adjustment, never raising CPU priority.
lower_priority() {
    local pid="$1" result
    same_process "$pid" || { drop_target "$pid"; return; }
    if (( PROC_NICE >= NICE_VALUE )); then
        log INFO "PID $pid already has nice value $PROC_NICE; no priority increase attempted."
    elif [[ "$DRY_RUN" == true ]]; then
        log WARN "DRY-RUN: would renice PID $pid from $PROC_NICE to $NICE_VALUE."
    else
        log WARN "Attempting renice PID $pid from $PROC_NICE to $NICE_VALUE."
        if result=$(renice "$NICE_VALUE" -p "$pid" 2>&1); then
            if same_process "$pid" && (( PROC_NICE >= NICE_VALUE )); then
                log INFO "Priority change confirmed for PID $pid: nice=$PROC_NICE."
            else
                log ERROR "Could not confirm priority change for PID $pid; stopping its monitoring."
                ACTIVE[$pid]=0
                return
            fi
        else
            log ERROR "renice failed for PID $pid: $result; stopping its monitoring."
            ACTIVE[$pid]=0
            return
        fi
    fi
    STAGES[$pid]=reniced
    BREACHES[$pid]=0
}

# send_signal logs the attempt and result; it never targets a process group.
send_signal() {
    local pid="$1" signal_name="$2" now="$3" result
    same_process "$pid" || { drop_target "$pid"; return; }
    if [[ "$DRY_RUN" == true ]]; then
        log WARN "DRY-RUN: would send $signal_name to PID $pid ($PROC_NAME)."
    else
        log WARN "Attempting $signal_name to PID $pid ($PROC_NAME)."
        if result=$(kill -s "$signal_name" "$pid" 2>&1); then
            log INFO "$signal_name delivered to PID $pid; delivery does not prove exit."
        else
            log ERROR "$signal_name failed for PID $pid: $result; stopping its monitoring."
            ACTIVE[$pid]=0
            return
        fi
    fi
    if [[ "$signal_name" == TERM ]]; then
        STAGES[$pid]=terminating
        TERM_TIMES[$pid]="$now"
    else
        STAGES[$pid]=kill_sent
    fi
}

# process_sample implements independent consecutive-breach counters for every PID.
process_sample() {
    local pid="$1" now="$2" ticks="$3" rss="$4" cpu memory excessive elapsed
    # A process counter going backwards indicates an invalid measurement.
    if (( ticks < LAST_TICKS[$pid] )); then
        log WARN "Invalid CPU counter for PID $pid; resetting its baseline."
        LAST_TICKS[$pid]="$ticks"
        LAST_UPTIME[$pid]="$now"
        BREACHES[$pid]=0
        return
    fi
    read -r cpu memory excessive elapsed < <(
        awk -v ticks="$ticks" -v old_ticks="${LAST_TICKS[$pid]}" \
            -v now="$now" -v old_time="${LAST_UPTIME[$pid]}" -v hz="$CLOCK_TICKS" \
            -v rss="$rss" -v pages="$PAGE_SIZE" -v total="$TOTAL_MEMORY" \
            -v cpu_limit="$CPU_THRESHOLD" -v mem_limit="$MEM_THRESHOLD" '
            BEGIN {
                elapsed = now - old_time
                if (elapsed <= 0) exit 1
                cpu = (ticks - old_ticks) / hz / elapsed * 100
                mem = rss * pages / 1024 / total * 100
                printf "%.2f %.2f %d %.2f\n", cpu, mem, (cpu > cpu_limit || mem > mem_limit), elapsed
            }
        '
    ) || { log WARN "Invalid measurement interval for PID $pid; skipping action."; BREACHES[$pid]=0; return; }
    LAST_TICKS[$pid]="$ticks"
    LAST_UPTIME[$pid]="$now"
    log INFO "PID $pid CPU=$cpu% (limit $CPU_THRESHOLD%), RAM=$memory% (limit $MEM_THRESHOLD%), stage=${STAGES[$pid]}."

    if [[ "${STAGES[$pid]}" == terminating ]]; then
        if awk -v now="$now" -v sent="${TERM_TIMES[$pid]}" -v grace="$TERM_GRACE" \
            'BEGIN { exit !(now - sent >= grace) }'; then
            send_signal "$pid" KILL "$now"
        fi
        return
    fi
    # Do not repeatedly send SIGKILL if exit is delayed (e.g. uninterruptible sleep).
    if [[ "${STAGES[$pid]}" == kill_sent ]]; then return; fi

    if [[ "$excessive" -eq 0 ]]; then
        if (( BREACHES[$pid] > 0 )); then log INFO "PID $pid recovered; consecutive-breach count reset."; fi
        BREACHES[$pid]=0
        return
    fi
    BREACHES[$pid]=$(( ${BREACHES[$pid]} + 1 ))
    log WARN "PID $pid exceeded CPU and/or RAM limits (${BREACHES[$pid]}/$BREACH_LIMIT consecutive samples)."
    if (( BREACHES[$pid] >= BREACH_LIMIT )); then
        case "${STAGES[$pid]}" in
            monitor) lower_priority "$pid" ;;
            reniced) send_signal "$pid" TERM "$now" ;;
        esac
    fi
}

# monitor_targets sleeps between shared sampling cycles, avoiding a busy loop.
monitor_targets() {
    local pid cycle=0 active_count now remainder
    while true; do
        active_count=0
        for pid in "${PIDS[@]}"; do
            if [[ "${ACTIVE[$pid]}" == 1 ]]; then active_count=$(( active_count + 1 )); fi
        done
        if [[ "$active_count" -eq 0 ]]; then log INFO 'All targets finished or were removed; exiting.'; return; fi
        if [[ "$MAX_CYCLES" -ne 0 && "$cycle" -ge "$MAX_CYCLES" ]]; then
            log INFO 'Configured monitoring-cycle limit reached; exiting.'
            return
        fi
        sleep "$INTERVAL"
        cycle=$(( cycle + 1 ))
        for pid in "${PIDS[@]}"; do
            [[ "${ACTIVE[$pid]}" == 1 ]] || continue
            if ! same_process "$pid"; then drop_target "$pid"; continue; fi
            read -r now remainder < /proc/uptime
            process_sample "$pid" "$now" "$PROC_TICKS" "$PROC_RSS"
        done
    done
}

# main prepares logging and target identities before beginning background monitoring.
main() {
    parse_arguments "$@"
    validate_environment
    trap 'log INFO "Watchdog interrupted; exiting."; exit 130' INT
    trap 'log INFO "Watchdog termination requested; exiting."; exit 143' TERM
    log INFO "Watchdog started: CPU>$CPU_THRESHOLD%, RAM>$MEM_THRESHOLD%, interval=${INTERVAL}s, breaches=$BREACH_LIMIT, nice=$NICE_VALUE, grace=${TERM_GRACE}s, dry-run=$DRY_RUN."
    protect_ancestors
    initialize_targets
    monitor_targets
    log INFO 'Watchdog stopped. Priority changes are not automatically restored.'
}

# ====================================================================================
# SCRIPT START
# ====================================================================================

main "$@"

