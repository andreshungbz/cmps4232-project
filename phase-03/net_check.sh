#!/bin/bash
# ====================================================================================
# net_check.sh - Append Ubuntu host network diagnostics to the persistent dashboard.
# Usage: sudo ./net_check.sh [options]
# Exit codes: 0 = all checks passed; 1 = report published with failed checks;
#             2 = configuration, dependency, locking, or publication failure.
# ====================================================================================

set -Eeuo pipefail

export LC_ALL=C
export TZ=America/Belize
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ====================================================================================
# VARIABLES
# ====================================================================================

# Resolve presentation files relative to this script, not the caller's directory.
NET_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPORT_TEMPLATE="$NET_SCRIPT_DIR/templates/net-report-header.html"

CONTAINER=health-dashboard
OUTPUT=/srv/health-dashboard/metrics/net_status.html
HOST=example.com
IP_TARGET=8.8.8.8
URL=https://example.com/
TIMEOUT=10
WORK_DIR=""
FAILED=0
CHECK_NUMBER=0
MARKER='<!-- net_check history v1 -->'
FOOTER='</main></body></html>'

# ====================================================================================
# FUNCTIONS
# ====================================================================================

# Print timestamped messages, sending warnings and errors to standard error.
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

# Report an operational error and exit with status 2.
die() { log ERROR "$1"; exit 2; }

# Display command options, defaults, and exit-code meanings.
usage() {
    cat <<'HELP'
Usage: sudo ./net_check.sh [options]
  --container NAME  Docker container (default: health-dashboard)
  --output FILE     Existing trusted parent directory; report file may be new
  --host HOST       DNS hostname for resolution and ICMP (default: example.com)
  --ip ADDRESS      Numeric IPv4 ping target (default: 8.8.8.8)
  --url URL         HTTPS endpoint (default: https://example.com/)
  --timeout SEC     Per-command deadline, integer 1-60 (default: 10)
  --help            Display help without running checks
Checks run on the Ubuntu host, not inside the container. ICMP failure alone does
not prove an Internet outage. Counters are cumulative, not transfer rates.
Previous report sections are retained. Exit 1 means a report with failed checks
was published; exit 2 means the run could not safely finish. No network settings
are modified. Report history grows until the administrator archives it.
HELP
}

# Read command-line options and validate targets, paths, and timeout settings.
parse_arguments() {
    while (( $# )); do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --container|--output|--host|--ip|--url|--timeout)
                [[ $# -ge 2 && -n "$2" ]] || die "Option '$1' needs a value."
                case "$1" in
                    --container) CONTAINER="$2" ;; --output) OUTPUT="$2" ;;
                    --host) HOST="$2" ;; --ip) IP_TARGET="$2" ;; --url) URL="$2" ;; --timeout) TIMEOUT="$2" ;;
                esac
                shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ "$CONTAINER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'Invalid container name.'
    [[ "$TIMEOUT" =~ ^([1-9]|[1-5][0-9]|60)$ ]] || die 'Timeout must be 1-60 seconds.'
    [[ ${#HOST} -le 253 && "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die 'Invalid hostname.'

    # Validate four decimal octets; reject ambiguous leading zeros and hostnames.
    [[ "$IP_TARGET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die 'Supply a numeric IPv4 address for --ip.'

    local octet
    local -a octets

    IFS=. read -r -a octets <<< "$IP_TARGET"

    for octet in "${octets[@]}"; do
        [[ "$octet" == 0 || "$octet" != 0* ]] || die 'IPv4 octets must not have leading zeros.'
        (( 10#$octet <= 255 )) || die 'IPv4 octets must be 0-255.'
    done

    [[ "$URL" == https://?* && ! "$URL" =~ [[:space:][:cntrl:]] ]] || die 'Supply an HTTPS URL without whitespace.'
    [[ -n "$OUTPUT" && ! "$OUTPUT" =~ [[:cntrl:]] ]] || die 'Invalid output path.'
}

# Escape diagnostic output before placing it inside HTML, including error messages.
html_escape() {
    sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# Remove this run's private temporary directory when the script exits.
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
}

# Validate dependencies and the report destination, then lock and prepare it.
prepare_output() {
    [[ "$EUID" -eq 0 ]] || die 'Run on Ubuntu with sudo for complete process and Docker information.'

    local name parent owner mode

    for name in awk bash ip ss docker getent ping curl timeout flock stat mktemp sed head tail chmod mv date dirname basename cat rm; do
        command -v "$name" >/dev/null || die "Required command '$name' is unavailable."
    done

    parent=$(dirname -- "$OUTPUT")
    [[ -d "$parent" ]] || die "Output directory does not exist: $parent"
    parent=$(cd -- "$parent" && pwd -P)
    OUTPUT="$parent/$(basename -- "$OUTPUT")"

    # Parent directory must not allow untrusted users to replace files during a run.
    owner=$(stat -c %u -- "$parent")
    mode=$(stat -c %a -- "$parent")
    [[ "$owner" == 0 ]] && (( (8#$mode & 0022) == 0 )) || die 'Output directory must be root-owned and not group/world-writable.'
    [[ ! -L "$OUTPUT" && ( ! -e "$OUTPUT" || -f "$OUTPUT" ) ]] || die 'Output must be a regular file, not a symlink or directory.'
    [[ ! -L "$OUTPUT.lock" && ( ! -e "$OUTPUT.lock" || -f "$OUTPUT.lock" ) ]] || die 'Invalid lock file.'

    umask 077
    exec 9>>"$OUTPUT.lock"
    flock -w 5 9 || die 'Another report run holds the lock; try again later.'

    # Keep the lock file in place: deleting it can allow competing locks.
    if [[ -e "$OUTPUT" ]]; then
        [[ "$(head -n 1 -- "$OUTPUT")" == "$MARKER" && "$(tail -n 1 -- "$OUTPUT")" == "$FOOTER" ]] || die 'Existing report format is unrecognized; preserve or archive it before proceeding.'
    fi

    WORK_DIR=$(mktemp -d "$parent/.net_check.XXXXXX")
}

# Display arguments with readable shell quotes; execution still uses the original array.
format_command() {
    local arg separator='' quoted

    for arg in "$@"; do
        printf '%s' "$separator"
        case "$arg" in
            ''|*[!a-zA-Z0-9_./:=,@%+-]*)
                # A literal apostrophe closes the quote, escapes itself, and reopens it.
                quoted=${arg//\'/\'\\\'\'}
                printf "'%s'" "$quoted"
                ;;
            *) printf '%s' "$arg" ;;
        esac
        separator=' '
    done
}

# Record failures and continue collecting other checks. Every command is bounded.
run_check() {
    local title="$1" status=PASS rc=0
    shift

    CHECK_NUMBER=$((CHECK_NUMBER + 1))

    if timeout --kill-after=2s "${TIMEOUT}s" "$@" > "$WORK_DIR/check" 2>&1; then
        log INFO "$title: PASS"
    else
        rc=$?
        status=FAIL
        FAILED=$((FAILED + 1))
        log WARN "$title: FAIL (exit $rc); continuing."
    fi

    {
        printf '<details class="check" data-result="%s"%s><summary>%s - %s</summary>\n' "$status" "$([[ $status == FAIL ]] && printf ' open')" "$title" "$status"
        printf '<p>Command: <code>'
        format_command "$@" | html_escape
        printf '</code> ∙ Exit: %s</p><pre>\n' "$rc"
        if [[ -s "$WORK_DIR/check" ]]; then html_escape < "$WORK_DIR/check"; else printf '(No output)\n'; fi
        printf '</pre></details>\n'
    } >> "$WORK_DIR/section"
}

# Collect host and container diagnostics into a timestamped report section.
collect_checks() {
    local token_file report_id timestamp label

    # Reserve a unique token even when multiple reports start in the same second.
    token_file=$(mktemp "$WORK_DIR/run.XXXXXXXXXXXX")
    report_id="report-${token_file##*.}"
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    label=$(date '+%d %b %Y, %I:%M:%S %p %Z')

    printf '<section class="report-entry" id="%s" data-report-version="2" data-timestamp="%s"><h2>Run: %s</h2>\n' \
        "$report_id" "$timestamp" "$label" > "$WORK_DIR/section"


    printf '<div class="check-group"><h3>Active Interface Statistics</h3>\n' >> "$WORK_DIR/section"
    run_check 'Interface Addresses' ip -brief address show
    run_check 'Interface Traffic' ip -s link show up
    run_check 'IPv4 Routes' ip -4 route show
    run_check 'IPv6 Routes' ip -6 route show
    printf '</div>\n' >> "$WORK_DIR/section"

    printf '<div class="check-group"><h3>DNS Resolution</h3>\n' >> "$WORK_DIR/section"
    run_check 'DNS Configuration' resolvectl status
    run_check 'Hostname Lookup' getent ahosts "$HOST"
    run_check 'Domain Reachability' ping -n -c 2 -W 2 "$HOST"
    printf '</div>\n' >> "$WORK_DIR/section"

    printf '<div class="check-group"><h3>Listening Ports</h3>\n' >> "$WORK_DIR/section"
    run_check 'Active Network Sockets' ss -lntup
    printf '</div>\n' >> "$WORK_DIR/section"

    printf '<div class="check-group"><h3>Container Port Bindings</h3>\n' >> "$WORK_DIR/section"
    run_check 'Container State' docker inspect --type container --format '{{.State.Status}}' "$CONTAINER"
    run_check 'Container Running Flag' docker inspect --type container --format '{{.State.Running}}' "$CONTAINER"
    run_check 'Published Ports' docker port "$CONTAINER"
    printf '</div>\n' >> "$WORK_DIR/section"

    printf '<div class="check-group"><h3>External Host Connectivity</h3>\n' >> "$WORK_DIR/section"
    run_check 'IPv4 Reachability' ping -4 -n -c 2 -W 2 "$IP_TARGET"
    run_check 'HTTPS Reachability' curl -q --noproxy '*' -fsS -m "$TIMEOUT" -o /dev/null -w 'HTTP=%{http_code} Remote=%{remote_ip} Total=%{time_total}s\n' "$URL"
    printf '</div>\n' >> "$WORK_DIR/section"

    printf '<p class="report-summary" data-checks="%s" data-failed="%s">Checks: %s, Failed: %s. PASS means the named command succeeded, not that every reported metric is healthy.</p></section>\n' "$CHECK_NUMBER" "$FAILED" "$CHECK_NUMBER" "$FAILED" >> "$WORK_DIR/section"
}

# Copy static presentation markup as data; never execute or expand the template.
write_report_header() {
    [[ -f "$REPORT_TEMPLATE" && -r "$REPORT_TEMPLATE" ]] || die "Cannot read report template: $REPORT_TEMPLATE"

    # This is a document prefix: closing the page here strands appended reports.
    if ! awk 'tolower($0) ~ /<\/[[:space:]]*(main|body|html)[[:space:]]*>/ { invalid = 1 } END { exit invalid }' "$REPORT_TEMPLATE"; then
        die 'Report header must not close main, body, or html; remove those closing tags from the template.'
    fi

    printf '%s\n' "$MARKER"
    cat -- "$REPORT_TEMPLATE"
}

# Preserve report history and atomically publish the completed HTML document.
publish_report() {
    # Always use the current presentation, even when history already exists.
    write_report_header > "$WORK_DIR/report" || die 'Cannot create report header.'

    if [[ -e "$OUTPUT" ]]; then
        [[ "$(head -n 1 -- "$OUTPUT")" == "$MARKER" && "$(tail -n 1 -- "$OUTPUT")" == "$FOOTER" ]] || die 'Existing report format is unrecognized; previous report preserved.'

        # Generated history starts at a section on its own line. Diagnostic text
        # is HTML-escaped, so it cannot be mistaken for this document boundary.
        # Retain every history line, dropping only the final document footer.
        awk -v footer="$FOOTER" '
            /^<section([ >])/ { copying = 1 }
            copying {
                if (have_line) print previous
                previous = $0
                have_line = 1
            }
            END { if (!copying || previous != footer) exit 1 }
        ' "$OUTPUT" >> "$WORK_DIR/report" || die 'Cannot identify existing history; previous report preserved.'
    fi

    cat "$WORK_DIR/section" >> "$WORK_DIR/report"
    printf '%s\n' "$FOOTER" >> "$WORK_DIR/report"

    chmod 0644 "$WORK_DIR/report"

    # Temporary file and destination share a filesystem; publish the complete page.
    mv -f -- "$WORK_DIR/report" "$OUTPUT" || die "Cannot publish report; previous report preserved."

    log INFO "Published $CHECK_NUMBER checks ($FAILED failed) to $OUTPUT."
}

# Set up cleanup and error handling, collect checks, and publish the report.
main() {
    parse_arguments "$@"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'printf "ERROR: Report generation failed; inspect the preceding error.\n" >&2; exit 2' ERR

    prepare_output
    collect_checks
    publish_report

    if (( FAILED > 0 )); then exit 1; fi
}

# ====================================================================================
# SCRIPT START
# ====================================================================================
main "$@"
