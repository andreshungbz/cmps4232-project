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
log() {
    local level="$1" message="$2" fd=1
    if [[ "$level" == ERROR || "$level" == WARN ]]; then fd=2; fi
    printf '[%s] [%s] %s\n' "$(date '+%d %b %Y, %I:%M:%S %p %Z')" "$level" "$message" >&"$fd"
}

die() { log ERROR "$1"; exit 2; }

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

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
}

prepare_output() {
    [[ "$EUID" -eq 0 ]] || die 'Run on Ubuntu with sudo for complete process and Docker information.'
    local name parent owner mode
    for name in bash ip ss docker getent ping curl timeout flock stat mktemp sed head tail chmod mv date dirname basename cat rm; do
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
        printf '<h3>%s — %s</h3>\n' "$title" "$status"
        printf '<p>Command: <code>'
        printf '%q ' "$@" | html_escape
        printf '</code> · Exit: %s</p><pre>\n' "$rc"
        if [[ -s "$WORK_DIR/check" ]]; then html_escape < "$WORK_DIR/check"; else printf '(No output)\n'; fi
        printf '</pre>\n'
    } >> "$WORK_DIR/section"
}

collect_checks() {
    printf '<section><h2>Run: %s</h2>\n' "$(date '+%d %b %Y, %I:%M:%S %p %Z')" > "$WORK_DIR/section"
    run_check 'Interface addresses and state' ip -brief address show
    run_check 'Active interface counters (cumulative)' ip -s link show up
    run_check 'IPv4 routes and gateways' ip -4 route show
    run_check 'IPv6 routes and gateways' ip -6 route show
    run_check 'DNS resolver configuration' resolvectl status
    run_check 'TCP listeners and unconnected UDP sockets' ss -lntup
    run_check 'Container state' docker inspect --type container --format '{{.State.Status}}' "$CONTAINER"
    run_check 'Container must be running' bash -c 'state=$(docker inspect --type container --format "{{.State.Running}}" "$1") && test "$state" = true' _ "$CONTAINER"
    run_check 'Configured container port bindings' docker inspect --type container --format '{{json .HostConfig.PortBindings}}' "$CONTAINER"
    run_check 'Published container ports' docker port "$CONTAINER"
    run_check 'Numeric IPv4 ICMP response (independent of DNS)' ping -4 -n -c 2 -W 2 "$IP_TARGET"
    run_check 'Hostname resolution (system resolver)' getent ahosts "$HOST"
    run_check 'ICMP response (may be filtered independently of HTTPS)' ping -n -c 2 -W 2 "$HOST"
    run_check 'HTTPS response (HTTP errors count as failures)' curl --disable --noproxy '*' --proto '=https' --fail --silent --show-error --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" --output /dev/null --write-out 'HTTP=%{http_code} Remote=%{remote_ip} Total=%{time_total}s\n' "$URL"
    printf '<p>Checks: %s; failed: %s. PASS means the named command succeeded, not that every reported metric is healthy.</p></section>\n' "$CHECK_NUMBER" "$FAILED" >> "$WORK_DIR/section"
}

publish_report() {
    if [[ -e "$OUTPUT" ]]; then
        # Remove only our closing line so new sections remain inside the document.
        sed '$d' "$OUTPUT" > "$WORK_DIR/report"
    else
        cat > "$WORK_DIR/report" <<HTML
$MARKER
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Network diagnostic history</title>
<style>body{font-family:system-ui,sans-serif;margin:2rem;color:#172b3a}main{max-width:75rem;margin:auto}section{border-top:2px solid #ccd5dd;margin-top:2rem}pre{background:#f3f5f7;padding:1rem;overflow:auto}code{overflow-wrap:anywhere}</style>
</head><body><main><h1>Network diagnostic history</h1>
<p>Ubuntu host measurements, oldest first. Check timestamps for freshness. Interface counters are cumulative. Failed ICMP does not by itself establish an Internet outage. HTTPS uses a direct connection without a proxy.</p>
HTML
    fi
    cat "$WORK_DIR/section" >> "$WORK_DIR/report"
    printf '%s\n' "$FOOTER" >> "$WORK_DIR/report"
    chmod 0644 "$WORK_DIR/report"
    # Temporary file and destination share a filesystem; publish the complete page.
    mv -f -- "$WORK_DIR/report" "$OUTPUT" || die "Cannot publish report; previous report preserved."
    log INFO "Published $CHECK_NUMBER checks ($FAILED failed) to $OUTPUT."
}

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

