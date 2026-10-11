#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

# Extract only log(), without running the provisioning script.
# This matches its current format: an unindented closing brace.
awk '
    /^log\(\) \{$/ { copying = 1 }
    copying { print }
    copying && /^}$/ { complete = 1; exit }
    END { if (!complete) exit 1 }
' "$SCRIPT_DIR/sys_init.sh" > "$TEST_DIR/log_function.sh"

bash -n "$TEST_DIR/log_function.sh"
source "$TEST_DIR/log_function.sh"
LOG_FILE="$TEST_DIR/sys_init.log"

check_equal() {
    local label="$1"
    local expected="$2"
    local actual="$3"

    if diff -u -- "$expected" "$actual"; then
        printf 'PASS: %s\n' "$label"
    else
        printf 'FAIL: %s\n' "$label" >&2
        exit 1
    fi
}

{
    log INFO "info message"
    log USER "user message"
    log WARN "warning message"
    log ERROR "error message"
} > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr"

printf '[\033[0;34mINFO\033[0m] info message\n[\033[0;35mUSER\033[0m] user message\n' \
    > "$TEST_DIR/expected_stdout"

printf '[\033[0;33mWARN\033[0m] warning message\n[\033[0;31mERROR\033[0m] error message\n' \
    > "$TEST_DIR/expected_stderr"

check_equal "INFO and USER go only to stdout" \
    "$TEST_DIR/expected_stdout" "$TEST_DIR/stdout"

check_equal "WARN and ERROR go only to stderr" \
    "$TEST_DIR/expected_stderr" "$TEST_DIR/stderr"

log USER "Enter username:" prompt \
    > "$TEST_DIR/prompt_stdout" 2> "$TEST_DIR/prompt_stderr"

printf '[\033[0;35mUSER\033[0m] Enter username: ' \
    > "$TEST_DIR/expected_prompt"

check_equal "Prompt ends with a space and no newline" \
    "$TEST_DIR/expected_prompt" "$TEST_DIR/prompt_stdout"

: > "$TEST_DIR/empty"
check_equal "USER prompt leaves stderr empty" \
    "$TEST_DIR/empty" "$TEST_DIR/prompt_stderr"

# Remove the timestamp prefix to compare the saved messages.
sed 's/^\[[^]]*\] //' "$LOG_FILE" > "$TEST_DIR/log_messages"

printf '%s\n' \
    '[INFO] info message' \
    '[USER] user message' \
    '[WARN] warning message' \
    '[ERROR] error message' \
    '[USER] Enter username:' > "$TEST_DIR/expected_log"

check_equal "All messages are logged without terminal colors" \
    "$TEST_DIR/expected_log" "$TEST_DIR/log_messages"

printf '\nAll logging tests passed.\n'
