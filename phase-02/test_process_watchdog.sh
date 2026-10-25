#!/usr/bin/env bash

# ====================================================================================
# test_process_watchdog.sh - Test monitoring decisions without changing real processes.
# Place beside process_watchdog.sh. Run with bash; no sudo is needed.
# Linux /proc integration is verified separately on the Ubuntu project server.
# ====================================================================================

# Exit on unhandled failures, unset variables, or failures within pipelines.
set -euo pipefail

# Resolve script locations regardless of the current working directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SCRIPT_DIR/process_watchdog.sh"
# Keep mock action evidence and logs private to this test run.
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

# fail reports the failed assertion and ends testing.
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# pass reports a successfully completed test case.
pass() { printf 'PASS: %s\n' "$1"; }

bash -n "$WATCHDOG"
# Load function definitions without invoking main or reading actual /proc entries.
awk '/^# SCRIPT START/ { exit } { print }' "$WATCHDOG" > "$TEST_DIR/functions.sh"
source "$TEST_DIR/functions.sh"

# Mocks replace every operation that could modify a real process.
read_process() {
    PROC_START="$MOCK_START"
    PROC_UID="$MOCK_UID"
    PROC_STATE="$MOCK_STATE"
    PROC_NAME='test-process'
    PROC_NICE=$(cat "$TEST_DIR/nice")
    PROC_PARENT=1
    PROC_RSS=0
    PROC_TICKS=1000
}
renice() {
    printf 'renice %s\n' "$*" >> "$TEST_DIR/actions"
    printf '%s\n' "$1" > "$TEST_DIR/nice"
}
kill() { printf 'kill %s\n' "$*" >> "$TEST_DIR/actions"; }

# setup_case initializes predictable metrics and one selected simulated process.
setup_case() {
    LOG_FILE="$TEST_DIR/watchdog.log"
    : > "$LOG_FILE"
    : > "$TEST_DIR/actions"
    printf '0\n' > "$TEST_DIR/nice"
    MOCK_START=777
    MOCK_UID="$EUID"
    MOCK_STATE=R
    CLOCK_TICKS=100
    PAGE_SIZE=4096
    TOTAL_MEMORY=100000
    ACTIVE[12345]=1
    START_TIMES[12345]=777
    OWNERS[12345]="$EUID"
    LAST_TICKS[12345]=1000
    LAST_UPTIME[12345]=100
    STAGES[12345]=monitor
    BREACHES[12345]=0
}

# run_case isolates settings/state and hides routine measurement messages.
run_case() {
    local label="$1" function_name="$2"
    ( setup_case; "$function_name" ) > "$TEST_DIR/case_stdout" 2> "$TEST_DIR/case_stderr"
    pass "$label"
}

# CPU remains exactly at the threshold; comparison must be strictly greater.
test_boundary() {
    process_sample 12345 105 1400 2500
    [[ "${BREACHES[12345]}" == 0 ]] || fail 'Equality must not count as excessive.'
    [[ ! -s "$TEST_DIR/actions" ]] || fail 'No action expected at the threshold.'
}

test_staged_actions() {
    local sample
    for sample in 1 2 3; do process_sample 12345 "$((100 + sample * 5))" "$((1000 + sample * 500))" 0; done
    [[ "${STAGES[12345]}" == reniced ]] || fail 'Three breaches must lower priority.'
    for sample in 4 5 6; do process_sample 12345 "$((100 + sample * 5))" "$((1000 + sample * 500))" 0; done
    [[ "${STAGES[12345]}" == terminating ]] || fail 'Further breaches must send TERM.'
    TERM_GRACE=10
    process_sample 12345 135 4500 0
    [[ "${STAGES[12345]}" == terminating ]] || fail 'Must respect grace period.'
    process_sample 12345 140 5000 0
    [[ "${STAGES[12345]}" == kill_sent ]] || fail 'Must escalate after grace.'
    process_sample 12345 145 5500 0
    printf '%s\n' 'renice 10 -p 12345' 'kill -s TERM 12345' 'kill -s KILL 12345' > "$TEST_DIR/expected"
    diff -u "$TEST_DIR/expected" "$TEST_DIR/actions" || fail 'Action sequence or repetition is incorrect.'
}

test_recovery() {
    process_sample 12345 105 1500 0
    process_sample 12345 110 2000 0
    process_sample 12345 115 2000 0
    [[ "${BREACHES[12345]}" == 0 ]] || fail 'Recovery must reset breach count.'
    process_sample 12345 120 2500 0
    [[ "${BREACHES[12345]}" == 1 ]] || fail 'New breaches must start counting again.'
    [[ ! -s "$TEST_DIR/actions" ]] || fail 'Brief spikes must not trigger actions.'
}

test_memory() {
    BREACH_LIMIT=1
    process_sample 12345 105 1000 3000
    [[ "${STAGES[12345]}" == reniced ]] || fail 'Memory excess alone must trigger the policy.'
}

test_dry_run() {
    BREACH_LIMIT=1
    DRY_RUN=true
    process_sample 12345 105 1500 0
    process_sample 12345 110 2000 0
    process_sample 12345 115 2500 0
    [[ "${STAGES[12345]}" == kill_sent ]] || fail 'Dry-run must simulate all action stages.'
    [[ ! -s "$TEST_DIR/actions" ]] || fail 'Dry-run must never call renice or kill.'
    grep -Fq 'DRY-RUN' "$LOG_FILE" || fail 'Dry-run decisions must be logged.'
}

test_identity_change() {
    MOCK_START=888
    lower_priority 12345
    [[ "${ACTIVE[12345]}" == 0 && ! -s "$TEST_DIR/actions" ]] || fail 'Changed PID identity must prevent actions.'
    ACTIVE[12345]=1
    MOCK_START=777
    MOCK_UID=$(( EUID + 1 ))
    send_signal 12345 TERM 105
    [[ "${ACTIVE[12345]}" == 0 && ! -s "$TEST_DIR/actions" ]] || fail 'Changed owner must prevent actions.'
}

test_command_failure() {
    renice() { return 1; }
    lower_priority 12345
    [[ "${ACTIVE[12345]}" == 0 ]] || fail 'Failed renice must stop further escalation for this target.'
    grep -Fq 'renice failed' "$LOG_FILE" || fail 'Command failure must be logged.'
}

test_nice_not_raised() {
    printf '15\n' > "$TEST_DIR/nice"
    lower_priority 12345
    [[ "${STAGES[12345]}" == reniced && ! -s "$TEST_DIR/actions" ]] || fail 'A process already at nice 15 must not be changed to 10.'
}

test_invalid_measurements() {
    BREACHES[12345]=2
    process_sample 12345 105 999 0
    [[ "${BREACHES[12345]}" == 0 && ! -s "$TEST_DIR/actions" ]] || fail 'Reversed CPU counter must not cause an action.'
    process_sample 12345 105 999 0
    [[ ! -s "$TEST_DIR/actions" ]] || fail 'Zero elapsed time must not cause an action.'
}

test_independent_targets() {
    ACTIVE[12346]=1
    START_TIMES[12346]=777
    OWNERS[12346]="$EUID"
    LAST_TICKS[12346]=1000
    LAST_UPTIME[12346]=100
    STAGES[12346]=monitor
    BREACHES[12346]=0
    process_sample 12345 105 1500 0
    process_sample 12346 105 1000 0
    [[ "${BREACHES[12345]}" == 1 && "${BREACHES[12346]}" == 0 ]] || fail 'Target counters must be independent.'
}

test_zombie() {
    MOCK_STATE=Z
    send_signal 12345 KILL 105
    [[ "${ACTIVE[12345]}" == 0 && ! -s "$TEST_DIR/actions" ]] || fail 'Do not signal a finished process.'
}

test_argument_validation() {
    local args
    for args in '--pids 0' '--pids 12345,' '--pids 12345 --memory 101' '--pids 12345 --interval 0' '--pids 12345 --nice 20'; do
        # Intentional splitting: the test cases above contain only simple option tokens.
        if ( parse_arguments $args ); then fail "Invalid arguments were accepted: $args"; fi
    done
    parse_arguments --pids 12345,12346 --cpu 150 --memory 20 --dry-run
    [[ "${#PIDS[@]}" == 2 && "$CPU_THRESHOLD" == 150 && "$DRY_RUN" == true ]] || fail 'Valid options must be accepted.'
}

run_case 'Threshold equality does not trigger actions' test_boundary
run_case 'Sustained CPU excess produces renice, TERM, then KILL after grace' test_staged_actions
run_case 'Recovery resets consecutive breaches' test_recovery
run_case 'Memory threshold independently triggers action' test_memory
run_case 'Dry-run logs decisions without process actions' test_dry_run
run_case 'Changed PID identity or owner prevents action' test_identity_change
run_case 'Failed priority change is logged and stops escalation' test_command_failure
run_case 'Existing lower priority is not raised' test_nice_not_raised
run_case 'Invalid measurement counters/intervals do not trigger action' test_invalid_measurements
run_case 'Each target has independent state' test_independent_targets
run_case 'Finished processes receive no signals' test_zombie
run_case 'Invalid options are rejected and valid options accepted' test_argument_validation
printf '\nAll watchdog decision tests passed. No real processes were modified.\n'

