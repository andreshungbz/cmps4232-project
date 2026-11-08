#!/bin/bash
# ====================================================================================
# sys_backup.sh - Archive Ubuntu configuration, logs, and dashboard persistent data.
# Usage: sudo ./sys_backup.sh [--destination DIR] [--nice NUMBER]
# Exit: 0 verified archive published; 1 source changed (archive NOT published);
#       2 setup, archive, or verification failure. Never deletes older backups.
# ====================================================================================

set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export TZ=America/Belize
unset TAR_OPTIONS GZIP

# ====================================================================================
# VARIABLES
# ====================================================================================

DESTINATION=/var/backups/phase-03
NICE_VALUE=10
WORK_DIR=""
ARCHIVE=""
SOURCES=(/etc /var/log /srv/health-dashboard/metrics)
RESERVE_BYTES=536870912

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

# Display backup options, source directories, and exit-code meanings.
usage() {
    cat <<'HELP'
Usage: sudo ./sys_backup.sh [--destination DIR] [--nice NUMBER] [--help]
  --destination DIR  Existing root-owned private directory (default: /var/backups/phase-03)
  --nice NUMBER      Positive niceness adjustment, 1-19 (default: 10)
Sources: /etc, /var/log, /srv/health-dashboard/metrics.
The destination must be outside the sources. Archives contain relative paths.
No retention deletion or scheduling is performed. A same-disk archive does not
protect against disk loss. Live archiving is not a filesystem snapshot.
Exit 0: verified archive published. Exit 1: source changed; retry later.
Exit 2: other failure. Incomplete archives are removed; older backups remain.
HELP
}

# Read command-line options and validate the niceness adjustment.
parse_arguments() {
    while (( $# )); do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --destination|--nice)
                [[ $# -ge 2 && -n "$2" ]] || die "Option '$1' requires a value."
                case "$1" in
                    --destination) DESTINATION="$2" ;;
                    --nice) NICE_VALUE="$2" ;;
                esac
                shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ "$NICE_VALUE" =~ ^([1-9]|1[0-9])$ ]] || die 'Nice adjustment must be 1-19.'
}

# Remove this run's temporary files while preserving published backups.
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
}

# Validate tools and paths, acquire locks, and create a private work directory.
prepare() {
    [[ "$EUID" == 0 ]] || die 'Run with sudo to read all required sources.'

    local command_name source canonical owner mode version

    for command_name in tar gzip nice ps df du stat flock mktemp date chmod mv realpath awk cat rm bash; do
        command -v "$command_name" >/dev/null || die "Missing dependency: $command_name"
    done

    version=$(tar --version)
    [[ "$version" == *'GNU tar'* ]] || die 'GNU tar is required.'

    [[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] || die 'Destination must be an existing directory, not a symlink.'
    DESTINATION=$(realpath -e -- "$DESTINATION")

    owner=$(stat -c %u -- "$DESTINATION")
    mode=$(stat -c %a -- "$DESTINATION")
    [[ "$owner" == 0 ]] && (( (8#$mode & 0077) == 0 )) || die 'Destination must be root-owned with no group/other access.'

    for source in "${SOURCES[@]}"; do
        [[ -d "$source" && ! -L "$source" ]] || die "Required source is missing or a symlink: $source"
        canonical=$(realpath -e -- "$source")
        [[ "$DESTINATION" != "$canonical" && "$DESTINATION" != "$canonical/"* ]] || die 'Backup destination must be outside every source.'
    done

    umask 077
    [[ ! -L "$DESTINATION/.backup.lock" && ( ! -e "$DESTINATION/.backup.lock" || -f "$DESTINATION/.backup.lock" ) ]] || die 'Invalid backup lock file.'
    exec 9>>"$DESTINATION/.backup.lock"
    flock -n 9 || die 'Another backup is running.'

    # Coordinate with net_check.sh so the metrics report is not replaced mid-read.
    local report_lock=/srv/health-dashboard/metrics/net_status.html.lock
    [[ ! -L "$report_lock" && ( ! -e "$report_lock" || -f "$report_lock" ) ]] || die 'Invalid diagnostic report lock.'
    exec 8>>"$report_lock"
    flock -w 15 8 || die 'Diagnostic report is busy; retry later.'

    WORK_DIR=$(mktemp -d "$DESTINATION/.sys_backup.XXXXXX")
}

# Estimate source sizes and require enough free space plus a safety reserve.
check_space() {
    local source size total=0 available needed

    for source in "${SOURCES[@]}"; do
        size=$(du -sb -- "$source" | awk '{print $1}')
        [[ "$size" =~ ^[0-9]+$ ]] || die 'Cannot measure source size.'
        total=$((total + size))
    done

    available=$(df -B1 --output=avail "$DESTINATION" | awk 'NR==2 {print $1}')
    [[ "$available" =~ ^[0-9]+$ ]] || die 'Cannot measure available disk space.'

    # Conservative estimate, not a guarantee: live sources and tar headers can grow.
    needed=$((total * 2 + RESERVE_BYTES))
    log INFO "Source estimate=$total bytes; available=$available; required estimate=$needed."
    (( available >= needed )) || die 'Insufficient free space for conservative estimate plus 512 MiB reserve.'
}

# Create a compressed archive at reduced priority and reject errors or warnings.
create_archive() {
    local source rc=0
    local -a relative=()

    for source in "${SOURCES[@]}"; do relative+=("${source#/}"); done

    # Bash records its inherited niceness, then execs tar with the SAME PID.
    # gzip launched by tar inherits that priority. No synthetic delay is added.
    nice -n "$NICE_VALUE" bash -c '
        printf "Archive worker priority (PID retained by tar):\n"
        ps -o pid,ni,comm -p "$$" || exit 2
        actual=$(ps -o ni= -p "$$") || exit 2
        (( actual >= $1 )) || { printf "Priority verification failed\n" >&2; exit 2; }
        shift
        exec tar --acls --xattrs --numeric-owner -czf "$1" -C / -- "${@:2}"
    ' _ "$NICE_VALUE" "$WORK_DIR/archive.tar.gz" "${relative[@]}" > "$WORK_DIR/priority.txt" 2> "$WORK_DIR/tar.stderr" || rc=$?

    cat "$WORK_DIR/priority.txt"
    cat "$WORK_DIR/tar.stderr" >&2

    case "$rc" in
        0) ;;
        1) log WARN 'Source changed during archiving. No final archive published; retry during a quieter period.'; return 1 ;;
        *) die "Archive creation failed (exit $rc). No final archive published." ;;
    esac

    # Do not silently accept skipped sockets or other GNU tar warnings as complete.
    [[ ! -s "$WORK_DIR/tar.stderr" ]] || die 'Tar emitted warnings; review them before retrying. No final archive published.'
}

# Check compression integrity and confirm every required source is included.
verify_archive() {
    nice -n "$NICE_VALUE" gzip -t "$WORK_DIR/archive.tar.gz" || die 'Gzip integrity check failed.'
    nice -n "$NICE_VALUE" tar -tzf "$WORK_DIR/archive.tar.gz" > "$WORK_DIR/members.txt" || die 'Archive listing verification failed.'
    [[ -s "$WORK_DIR/members.txt" ]] || die 'Archive is empty.'

    local source member found

    for source in "${SOURCES[@]}"; do
        found=false

        while IFS= read -r member; do
            if [[ "$member" == "${source#/}/" || "$member" == "${source#/}" ]]; then found=true; break; fi
        done < "$WORK_DIR/members.txt"

        [[ "$found" == true ]] || die "Required source missing from archive: $source"
    done
}

# Assign a unique timestamped name and publish the archive with private permissions.
publish_archive() {
    local stamp token

    stamp=$(date '+%Y%m%d_%H%M%S%z')
    token=${WORK_DIR##*/}
    token=${token##*.}
    ARCHIVE="$DESTINATION/sys_backup_${stamp}_${token}.tar.gz"
    [[ ! -e "$ARCHIVE" ]] || die 'Archive name collision.'

    chmod 0600 "$WORK_DIR/archive.tar.gz"
    mv -- "$WORK_DIR/archive.tar.gz" "$ARCHIVE"

    log INFO "Verified archive published: $ARCHIVE"
    log INFO 'Compression integrity and source entries verified; this is not an application-consistent snapshot.'
}

# Coordinate setup, archive creation, verification, publication, and cleanup.
main() {
    parse_arguments "$@"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'printf "ERROR: Backup stopped after an operational failure.\n" >&2; exit 2' ERR

    prepare
    check_space

    log INFO "Starting backup with niceness adjustment +$NICE_VALUE."

    if ! create_archive; then exit 1; fi

    verify_archive
    publish_archive
}

# ====================================================================================
# SCRIPT START
# ====================================================================================
main "$@"
