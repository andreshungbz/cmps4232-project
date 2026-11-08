#!/bin/bash
# Isolated report tests. No sudo, Docker, network traffic, or real reports needed.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

bash -n "$SCRIPT_DIR/net_check.sh"

# Load definitions without invoking the root-only host workflow.
sed '/^main "\$@"$/d' "$SCRIPT_DIR/net_check.sh" > "$TEST_DIR/functions.sh"
source "$TEST_DIR/functions.sh"

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
WORK_DIR="$TEST_DIR/work"
mkdir "$WORK_DIR"
OUTPUT="$TEST_DIR/net_status.html"

# Report a failed assertion and stop the test run.
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Print confirmation that a test group passed.
pass() { printf 'PASS: %s\n' "$1"; }

# Simulate external command results at the execution boundary.
timeout() {
    shift 2
    case "$1" in
        ping) printf 'ICMP timed out\n' >&2; return 124 ;;
        docker)
            if [[ "$2" == port ]]; then printf '80/tcp -> 127.0.0.1:8080\n';
            else printf 'running\n'; fi ;;
        *) printf 'sample <script> & "quoted"\n' ;;
    esac
}

collect_checks > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr"
[[ "$FAILED" == 2 && "$CHECK_NUMBER" == 14 ]] || fail 'Failed check count or continuation.'
grep -q 'HTTPS response' "$WORK_DIR/section" || fail 'HTTPS was skipped after ICMP failure.'
grep -q '&lt;script&gt; &amp; &quot;quoted&quot;' "$WORK_DIR/section" || fail 'HTML escaping.'
pass 'Timed-out ICMP is recorded; remaining checks continue; HTML is escaped.'

publish_report > /dev/null
[[ $(grep -c '<section>' "$OUTPUT") == 1 ]] || fail 'First run section.'
cp "$OUTPUT" "$TEST_DIR/first.html"
FAILED=0
CHECK_NUMBER=0

collect_checks > /dev/null 2>&1

publish_report > /dev/null
[[ $(grep -c '<section>' "$OUTPUT") == 2 ]] || fail 'History was overwritten.'
[[ $(grep -c '</main></body></html>' "$OUTPUT") == 1 ]] || fail 'Duplicate closing document.'
[[ $(head -n 1 "$OUTPUT") == "$MARKER" ]] || fail 'Missing format marker.'
pass 'Two runs preserve history in one document.'

# A failed replacement must leave the previous report intact.
cp "$OUTPUT" "$TEST_DIR/before.html"

# Mock file replacement failure to verify that existing history survives.
if ( mv() { return 1; }; publish_report ) > /dev/null 2>&1; then

    # An explicit publication guard is required even when invoked in a condition.
    fail 'Publication failure was ignored.'
fi
cmp "$OUTPUT" "$TEST_DIR/before.html" || fail 'Publication failure changed history.'
pass 'Failed publication preserves the existing report.'

if (parse_arguments --timeout 0) > /dev/null 2>&1; then fail 'Accepted invalid timeout.'; fi
if (parse_arguments --container '-invalid') > /dev/null 2>&1; then fail 'Accepted invalid container.'; fi
if (parse_arguments --url http://example.com) > /dev/null 2>&1; then fail 'Accepted non-HTTPS URL.'; fi
pass 'Invalid options are rejected.'

bash "$SCRIPT_DIR/net_check.sh" --help > /dev/null
pass 'Help works without sudo or host checks.'

# Exercise the real main flow with only host preparation and commands simulated.
# Locking and root-directory checks still require validation on Ubuntu.
run_main_case() {
    local scenario="$1" expected="$2" actual=0
    (
        FAILED=0
        CHECK_NUMBER=0

        # Use a private temporary report destination instead of host preparation.
        prepare_output() {
            WORK_DIR=$(mktemp -d "$TEST_DIR/run.XXXXXX")
            OUTPUT="$TEST_DIR/$scenario.html"
        }

        # Simulate command results for this scenario without network or Docker access.
        timeout() {
            shift 2
            case "$1" in
                bash)
                    if [[ "$scenario" == stopped ]]; then return 1; fi
                    ;;
                docker)
                    if [[ "$2" == port ]]; then
                        printf '80/tcp -> 127.0.0.1:8080\n'
                    elif [[ "$scenario" == stopped ]]; then
                        printf 'exited\n'
                    else
                        printf 'running\n'
                    fi
                    ;;
                *) printf 'Successful simulated result\n' ;;
            esac
        }

        main
    ) > "$TEST_DIR/$scenario.stdout" 2> "$TEST_DIR/$scenario.stderr" || actual=$?

    [[ "$actual" == "$expected" ]] || fail "$scenario exit: expected $expected, got $actual."
    [[ -s "$TEST_DIR/$scenario.html" ]] || fail "$scenario report was not published."
}

run_main_case healthy 0
pass 'Successful main flow publishes a report and exits 0.'

run_main_case stopped 1
grep -q 'Container must be running.*FAIL' "$TEST_DIR/stopped.html" || fail 'Stopped container not flagged.'
grep -q 'HTTPS response' "$TEST_DIR/stopped.html" || fail 'Stopped container prevented later checks.'
pass 'Stopped container produces exit 1 and preserves later diagnostics.'

actual=0
bash "$SCRIPT_DIR/net_check.sh" --timeout 0 > /dev/null 2>&1 || actual=$?

[[ "$actual" == 2 ]] || fail 'Invalid CLI settings must exit 2.'
pass 'Invalid CLI settings exit 2.'

# Validate the numeric target independently of DNS and reject option-like inputs.
(parse_arguments --ip 192.0.2.10) || fail 'Valid numeric IPv4 target rejected.'
for invalid in example.com 256.1.1.1 01.2.3.4 1.2.3 --help; do
    if (parse_arguments --ip "$invalid") > /dev/null 2>&1; then
        fail "Accepted invalid numeric target: $invalid"
    fi
done
pass 'Numeric IPv4 option accepts valid addresses and rejects malformed targets.'

# Simulate resolver inspection failure while allowing IP connectivity to succeed.
(
    FAILED=0
    CHECK_NUMBER=0

    # Simulate command results for this scenario without network or Docker access.
    timeout() {
        shift 2
        if [[ "$1" == resolvectl ]]; then printf 'Resolver unavailable\n'; return 1; fi
        printf 'Simulated success\n'
    }

    collect_checks > /dev/null 2>&1
    [[ "$FAILED" == 1 ]] || fail 'Resolver failure count.'
    grep -q 'DNS resolver configuration.*FAIL' "$WORK_DIR/section" || fail 'Resolver failure missing.'
    grep -q 'Numeric IPv4 ICMP response.*PASS' "$WORK_DIR/section" || fail 'Independent IP check missing.'
    grep -q 'IPv4 routes and gateways' "$WORK_DIR/section" || fail 'IPv4 routes missing.'
    grep -q 'IPv6 routes and gateways' "$WORK_DIR/section" || fail 'IPv6 routes missing.'
) || fail 'Resolver failure handling.'
pass 'Resolver failure is recorded while routes and independent IP checks continue.'
