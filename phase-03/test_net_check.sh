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

# Loaded definitions live in a temporary file; use the real presentation template.
REPORT_TEMPLATE="$SCRIPT_DIR/templates/net-report-header.html"

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
[[ "$FAILED" == 2 && "$CHECK_NUMBER" == 13 ]] || fail 'Failed check count or continuation.'
grep -q 'HTTPS Reachability' "$WORK_DIR/section" || fail 'HTTPS was skipped after ICMP failure.'
grep -q '&lt;script&gt; &amp; &quot;quoted&quot;' "$WORK_DIR/section" || fail 'HTML escaping.'
pass 'Timed-out ICMP is recorded; remaining checks continue; HTML is escaped.'

publish_report > /dev/null
[[ $(grep -c '<section ' "$OUTPUT") == 1 ]] || fail 'First run section.'
cp "$OUTPUT" "$TEST_DIR/first.html"
FAILED=0
CHECK_NUMBER=0

collect_checks > /dev/null 2>&1

publish_report > /dev/null
[[ $(grep -c '<section ' "$OUTPUT") == 2 ]] || fail 'History was overwritten.'
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
                docker)
                    if [[ "$2" == port ]]; then
                        printf '80/tcp -> 127.0.0.1:8080\n'
                    elif [[ "$*" == *'{{.State.Running}}'* ]]; then
                        if [[ "$scenario" == stopped ]]; then printf 'false\n'; else printf 'true\n'; fi
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

run_main_case stopped 0
grep -q 'Container Running Flag.*PASS' "$TEST_DIR/stopped.html" || fail 'Running flag query failed.'
grep -q '^false$' "$TEST_DIR/stopped.html" || fail 'Stopped running flag missing.'
grep -q '^true$' "$TEST_DIR/healthy.html" || fail 'Healthy running flag missing.'
grep -q 'HTTPS Reachability' "$TEST_DIR/stopped.html" || fail 'Stopped container prevented later checks.'
pass 'Running flag displays true or false; successful inspection preserves later diagnostics.'

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
    grep -q 'DNS Configuration.*FAIL' "$WORK_DIR/section" || fail 'Resolver failure missing.'
    grep -q 'IPv4 Reachability.*PASS' "$WORK_DIR/section" || fail 'Independent IP check missing.'
    grep -q 'IPv4 Routes' "$WORK_DIR/section" || fail 'IPv4 routes missing.'
    grep -q 'IPv6 Routes' "$WORK_DIR/section" || fail 'IPv6 routes missing.'
) || fail 'Resolver failure handling.'
pass 'Resolver failure is recorded while routes and independent IP checks continue.'


# A missing template must fail without publishing a partial new report.
(
    WORK_DIR=$(mktemp -d "$TEST_DIR/template.XXXXXX")
    OUTPUT="$TEST_DIR/missing-template.html"
    REPORT_TEMPLATE="$TEST_DIR/does-not-exist.html"
    printf '<section>fixture</section>\n' > "$WORK_DIR/section"
    rc=0
    (publish_report) > /dev/null 2>&1 || rc=$?
    [[ "$rc" == 2 && ! -e "$OUTPUT" ]] || fail 'Missing template published a report.'
) || fail 'Template failure handling.'
pass 'Missing template leaves a new report unpublished.'

# Templates are literal data, including shell-like text.
(
    REPORT_TEMPLATE="$TEST_DIR/literal.html"
    printf '%s\n' '<p>$HOME $(false)</p>' > "$REPORT_TEMPLATE"
    write_report_header > "$TEST_DIR/header.html"
    grep -Fq '<p>$HOME $(false)</p>' "$TEST_DIR/header.html" || fail 'Template content expanded.'
) || fail 'Literal template rendering.'
pass 'Template contents are copied without shell expansion.'

# New report identifiers must be distinct and preserved when history grows.
ids=$(sed -n '/^<section /s/.*id="\(report-[^"]*\)".*/\1/p' "$OUTPUT")
[[ $(printf '%s\n' "$ids" | sort -u | wc -l | tr -d ' ') == 2 ]] || fail 'Report identifiers are not unique.'
first_id=$(sed -n '/^<section /s/.*id="\(report-[^"]*\)".*/\1/p' "$TEST_DIR/first.html")
grep -Fq "id=\"$first_id\"" "$OUTPUT" || fail 'Existing report identifier changed.'
grep -q 'data-timestamp="[0-9].*"' "$OUTPUT" || fail 'Machine-readable timestamp missing.'
grep -q 'data-checks="13" data-failed="2"' "$OUTPUT" || fail 'Failure metadata does not match results.'
grep -q 'data-checks="13" data-failed="0"' "$TEST_DIR/healthy.html" || fail 'Healthy summary metadata incorrect.'
pass 'Unique identifiers persist and summary metadata matches diagnostic results.'

# Refresh presentation while preserving history exactly and appending a new run.
(
    WORK_DIR=$(mktemp -d "$TEST_DIR/refresh.XXXXXX")
    OUTPUT="$TEST_DIR/refresh.html"
    printf '%s\n' "$MARKER" '<html><body><main>OLD HEADER' > "$OUTPUT"
    printf '%s\n' '<section><h2>Legacy</h2><pre>Original &amp; evidence</pre></section>' > "$WORK_DIR/history"
    cat "$WORK_DIR/history" >> "$OUTPUT"
    printf '%s\n' "$FOOTER" >> "$OUTPUT"
    REPORT_TEMPLATE="$TEST_DIR/new-template.html"
    printf '%s\n' '<html><body><main>NEW HEADER' > "$REPORT_TEMPLATE"
    printf '%s\n' '<section id="report-test"><h2>New run</h2></section>' > "$WORK_DIR/section"
    publish_report > /dev/null
    grep -q 'NEW HEADER' "$OUTPUT" || fail 'Template was not refreshed.'
    if grep -q 'OLD HEADER' "$OUTPUT"; then fail 'Old header retained.'; fi
    sed -n '/^<section/,$p' "$OUTPUT" | sed '$d' > "$WORK_DIR/actual"
    cat "$WORK_DIR/history" "$WORK_DIR/section" > "$WORK_DIR/expected"
    cmp "$WORK_DIR/expected" "$WORK_DIR/actual" || fail 'History bytes changed.'
    cp "$OUTPUT" "$WORK_DIR/before"
    REPORT_TEMPLATE="$TEST_DIR/missing-template"
    rc=0
    (publish_report) > /dev/null 2>&1 || rc=$?
    [[ "$rc" == 2 ]] || fail 'Missing template should fail.'
    cmp "$OUTPUT" "$WORK_DIR/before" || fail 'Missing template changed existing history.'
) || fail 'Automatic template refresh.'
pass 'Current template replaces old header; history stays exact; missing template preserves report.'

# Unrecognized history must never be silently replaced with just the new run.
(
    WORK_DIR=$(mktemp -d "$TEST_DIR/invalid-history.XXXXXX")
    OUTPUT="$TEST_DIR/invalid-history.html"
    printf '%s\n' "$MARKER" '<main>Unrecognized history</main>' "$FOOTER" > "$OUTPUT"
    cp "$OUTPUT" "$WORK_DIR/before"
    rc=0
    (publish_report) > /dev/null 2>&1 || rc=$?
    [[ "$rc" == 2 ]] || fail 'Unrecognized history accepted.'
    cmp "$OUTPUT" "$WORK_DIR/before" || fail 'Unrecognized history changed.'
) || fail 'Invalid history handling.'
pass 'Unrecognized history is rejected without replacing the report.'

# A complete-page template must not strand report entries outside the main element.
(
    REPORT_TEMPLATE="$TEST_DIR/closed-template.html"
    printf '%s\n' '<html><body><main>Header</main></body></html>' > "$REPORT_TEMPLATE"
    rc=0
    (write_report_header) > /dev/null 2>&1 || rc=$?
    [[ "$rc" == 2 ]] || fail 'Premature document closing tags accepted.'
) || fail 'Header boundary validation.'
pass 'Template closing tags are rejected before report publication.'

# Display special arguments legibly while retaining their exact shell meaning.
formatted=$(format_command docker inspect --format '{{.State.Running}}' health-dashboard)
[[ "$formatted" == "docker inspect --format '{{.State.Running}}' health-dashboard" ]] || fail 'Readable Docker command.'
(
    args=('' 'two words' "it's quoted" '*' '{{json .HostConfig.PortBindings}}' 'HTTP=%{http_code}\n' '<tag>&')
    formatted=$(format_command "${args[@]}")
    eval "set -- $formatted"
    [[ "$#" == "${#args[@]}" ]] || fail 'Displayed argument count.'
    for arg in "${args[@]}"; do
        [[ "$1" == "$arg" ]] || fail 'Displayed argument changed.'
        shift
    done
) || fail 'Readable command quoting.'
pass 'Readable command quotes preserve spaces, apostrophes, wildcards, and literal backslashes.'

# Check the generated structure without relying on browser regrouping.
[[ $(grep -c '<div class="check-group">' "$TEST_DIR/healthy.html") == 5 ]] || fail 'Category count.'
[[ $(grep -c '<details class="check"' "$TEST_DIR/healthy.html") == 13 ]] || fail 'Check count.'
grep -q '<summary>Active Network Sockets — PASS</summary>' "$TEST_DIR/healthy.html" || fail 'Short title missing.'
if grep -q 'HostConfig.PortBindings' "$TEST_DIR/healthy.html"; then fail 'Duplicate port check remains.'; fi
pass 'Five categories and thirteen descriptive checks are generated directly.'
