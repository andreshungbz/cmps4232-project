#!/usr/bin/env bash

# ====================================================================================
# test_log_analyzer.sh - Tests the analyzer with temporary sample authentication logs.
# Place beside log_analyzer.sh. No sudo required; real logs/reports are not changed.
# ====================================================================================

# Exit on unhandled failures, unset variables, or failures within pipelines.
set -euo pipefail

# ====================================================================================
# VARIABLES
# ====================================================================================

# Locate this test script's directory, regardless of the current working directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Locate the analyzer script stored beside this test script.
ANALYZER="$SCRIPT_DIR/log_analyzer.sh"

# Create a private temporary directory for this test run's files.
TEST_DIR="$(mktemp -d)"

# Store sample authentication entries here instead of using the real system log.
AUTH_LOG="$TEST_DIR/auth.log"

# Save the test report here instead of replacing the real system audit report.
REPORT_FILE="$TEST_DIR/audit_report.txt"

# Remove only this test run's private temporary directory on exit.
trap 'rm -rf -- "$TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ====================================================================================
# FUNCTIONS
# ====================================================================================

# fail reports a failed check and any captured analyzer errors, then exits the test.
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    # Include analyzer errors to make a failed test easier to investigate.
    if [[ -s "$TEST_DIR/stderr" ]]; then
        cat "$TEST_DIR/stderr" >&2
    fi
    exit 1
}

# pass prints a confirmation that the named check succeeded.
pass() {
    printf 'PASS: %s\n' "$1"
}

# check_equal compares expected and actual file contents, reporting a pass or failure.
check_equal() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if diff -u -- "$expected" "$actual"; then
        pass "$label"
    else
        fail "$label"
    fi
}

# run_analyzer executes the entire real script, including parsing and publication.
run_analyzer() {
    bash "$ANALYZER" --input "$AUTH_LOG" --output "$REPORT_FILE" --top 2 "$@" \
        > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr"
}

# check_section compares a report section with known expected original entries.
check_section() {
    local title="$1"
    local expected="$2"
    awk -v title="$title" '
        $0 == title { copying = 1; next }
        copying && /^$/ { exit }
        copying && /^Root detection:/ { exit }
        copying { print }
    ' "$REPORT_FILE" > "$TEST_DIR/section"
    check_equal "$title" "$expected" "$TEST_DIR/section"
}

# ====================================================================================
# SCRIPT START
# ====================================================================================

[[ -f "$ANALYZER" ]] || fail "Place this test beside log_analyzer.sh."
bash -n "$ANALYZER" || fail "Analyzer syntax check"
pass "Analyzer Bash syntax is valid"

# Known matches include traditional and ISO timestamps, IPv4/IPv6, and all teammates.
cat > "$TEST_DIR/ssh" <<'LOG'
Oct 24 09:00:01 ubuntu sshd[101]: Failed password for andres from 192.0.2.1 port 2001 ssh2
2026-10-24T09:00:02-06:00 ubuntu sshd[102]: Failed publickey for invalid user unknown from 2001:db8::1 port 2002 ssh2
LOG
cat > "$TEST_DIR/sudo" <<'LOG'
Oct 24 09:00:03 ubuntu sudo: tysha : user NOT in sudoers ; TTY=pts/0 ; USER=root ; COMMAND=/usr/bin/id
2026-10-24T09:00:04-06:00 ubuntu sudo[104]: jennessa : command not allowed ; TTY=pts/1 ; USER=root ; COMMAND=/usr/bin/id
LOG
cat > "$TEST_DIR/root" <<'LOG'
Oct 24 09:00:05 ubuntu sudo[105]: pam_unix(sudo:session): session opened for user root(uid=0) by andres(uid=1000)
Oct 24 09:00:06 ubuntu su[106]: pam_unix(su:session): session opened for user root by jennessa(uid=1002)
LOG

# These must NOT appear in any of the report's matching-event sections.
cat > "$AUTH_LOG" <<'LOG'
Oct 24 09:01:01 ubuntu sshd[201]: Accepted password for andres from 192.0.2.1 port 2001 ssh2
Oct 24 09:01:02 ubuntu sshd[202]: Invalid user unknown from 192.0.2.1 port 2001
Oct 24 09:01:03 ubuntu sudo[203]: tysha : 1 incorrect password attempt ; USER=root ; COMMAND=/usr/bin/id
Oct 24 09:01:04 ubuntu sudo[204]: pam_unix(sudo:session): session opened for user root(uid=0) by root(uid=0)
Oct 24 09:01:05 ubuntu sudo[205]: pam_unix(sudo:session): session closed for user root
Oct 24 09:01:06 ubuntu logger[206]: Failed password for andres from 192.0.2.1 port 2001 ssh2
Oct 24 09:01:07 ubuntu sudo[207]: andres : TTY=pts/0 ; USER=root ; COMMAND=/usr/bin/echo user NOT in sudoers
Malformed sample entry
LOG
cat "$TEST_DIR/ssh" "$TEST_DIR/sudo" "$TEST_DIR/root" >> "$AUTH_LOG"

# Include a final record without a newline; it must still be detected.
printf '%s' 'Oct 24 09:02:01 ubuntu sshd[301]: Failed password for tysha from 192.0.2.2 port 2003 ssh2' >> "$AUTH_LOG"
printf '%s\n' 'Oct 24 09:02:01 ubuntu sshd[301]: Failed password for tysha from 192.0.2.2 port 2003 ssh2' >> "$TEST_DIR/ssh"

# Prefix the expected entries with the count that each report section must contain.
{ printf 'Matching records: 3\n'; cat "$TEST_DIR/ssh"; } > "$TEST_DIR/expected_ssh"
{ printf 'Matching records: 2\n'; cat "$TEST_DIR/sudo"; } > "$TEST_DIR/expected_sudo"
{ printf 'Matching records: 2\n'; cat "$TEST_DIR/root"; } > "$TEST_DIR/expected_root"

cp "$AUTH_LOG" "$TEST_DIR/original_input"
run_analyzer || fail "Analyzer runs successfully on sample input (requires Ubuntu procps and GNU mv)"
check_section '1. FAILED SSH LOGIN ATTEMPTS' "$TEST_DIR/expected_ssh"
check_section '2. UNAUTHORIZED SUDO ATTEMPTS' "$TEST_DIR/expected_sudo"
check_section '3. SUCCESSFUL ESCALATIONS TO ROOT' "$TEST_DIR/expected_root"
check_equal "Source log is unchanged" "$TEST_DIR/original_input" "$AUTH_LOG"

[[ ! -s "$TEST_DIR/stderr" ]] || fail "Successful execution leaves stderr empty"
grep -Fq '[INFO]' "$TEST_DIR/stdout" || fail "Progress messages go to stdout"
pass "Successful execution separates progress from errors"

grep -Eq '^Generated: .+ CST$' "$REPORT_FILE" || fail "Report has a Belize timestamp"
grep -Fqx 'Unrecognized nonblank record formats: 1' "$REPORT_FILE" || fail "Malformed record is counted"
[[ "$(ls -ld -- "$REPORT_FILE")" == -rw-------* ]] || fail "Report has owner-only permissions"
pass "Report includes a timestamp, malformed-record count, and restricted permissions"

# Inspect table structure; live PIDs, owners, and memory values change between runs.
awk '
    /^4\. TOP / { table = 1 }
    table && $1 ~ /^[0-9]+$/ {
        if (NF < 5 || $3 !~ /^[0-9]+([.][0-9]+)?$/ || $4 !~ /^[0-9]+$/) exit 1
        if (rows > 0 && $4 + 0 > previous) exit 1
        previous = $4 + 0
        rows++
    }
    END { if (rows < 1 || rows > 2) exit 1 }
' "$REPORT_FILE" || fail "Process table contains valid metrics sorted by decreasing RSS"
pass "Process table respects --top and sorts memory usage"

# Empty logs are valid input and must produce three explicit zero-result sections.
: > "$AUTH_LOG"
run_analyzer || fail "Empty input is handled successfully"
[[ "$(grep -Fc 'No matching events found.' "$REPORT_FILE")" -eq 3 ]] || fail "Empty log has three zero-result sections"
grep -Fqx 'Records read: 0' "$REPORT_FILE" || fail "Empty log has zero records"
pass "Empty input produces a valid report"

# An actual input error must not replace a previously completed report.
cp "$REPORT_FILE" "$TEST_DIR/previous_report"
if run_analyzer --input "$TEST_DIR/missing.log"; then
    fail "Missing input must return a nonzero status"
fi
grep -Fq '[ERROR]' "$TEST_DIR/stderr" || fail "Missing input reports its error on stderr"
check_equal "Missing input preserves the previous report" "$TEST_DIR/previous_report" "$REPORT_FILE"

if run_analyzer --top 0; then
    fail "Invalid process count must return a nonzero status"
fi
check_equal "Invalid process count preserves the previous report" "$TEST_DIR/previous_report" "$REPORT_FILE"

if run_analyzer --output "$AUTH_LOG"; then
    fail "The analyzer must reject its input file as the report destination"
fi
[[ ! -s "$AUTH_LOG" ]] || fail "Input was overwritten"
pass "Input cannot be overwritten by the report"

# No temporary analyzer workspace should remain after successful/failed runs.
for leftover in "$TEST_DIR"/.log_analyzer.*; do
    [[ ! -e "$leftover" ]] || fail "Analyzer temporary directory was not cleaned up"
done
pass "Analyzer cleans up its temporary files"

printf '\nAll log analyzer tests passed.\n'

