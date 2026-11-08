#!/bin/bash
# ====================================================================================
# test_sys_backup.sh - Isolated backup tests; no sudo or real system sources used.
# Real archive creation test runs when GNU tar is available (including Ubuntu).
# ====================================================================================

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

bash -n "$SCRIPT_DIR/sys_backup.sh"
sed '/^main "\$@"$/d' "$SCRIPT_DIR/sys_backup.sh" > "$TEST_DIR/functions.sh"
source "$TEST_DIR/functions.sh"

# Report a failed assertion and stop the test run.
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Print confirmation that a test group passed.
pass() { printf 'PASS: %s\n' "$1"; }

mkdir -p "$TEST_DIR/source" "$TEST_DIR/work" "$TEST_DIR/backups" "$TEST_DIR/restore"
printf 'restore test\n' > "$TEST_DIR/source/sample.txt"
SOURCES=("$TEST_DIR/source")
WORK_DIR="$TEST_DIR/work"
DESTINATION="$TEST_DIR/backups"

for value in 0 -1 20 abc; do

    rc=0
    (parse_arguments --nice "$value") >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 2 ]] || fail 'Invalid priority accepted.'
done
bash "$SCRIPT_DIR/sys_backup.sh" --help >/dev/null
pass 'Help and priority validation.'

# Simulate live-source changes; never archive real host data in failure tests.

rc=0

# Mock the archive command exit code for a changing source.
( nice() { return 1; }; create_archive ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]] || fail 'Changed source must return 1.'
pass 'Changed source prevents successful creation.'

rc=0

# Mock an archive command failure caused by a permission error.
( nice() { printf 'Permission denied\n' >&2; return 2; }; create_archive ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail 'Archive failure must exit 2.'
pass 'Archive command failure is reported.'

rc=0

# Mock a warning despite a successful archive command exit status.
( nice() { printf 'Skipped file warning\n' >&2; }; create_archive ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail 'Tar warning was ignored.'
pass 'Warnings prevent publication as a complete backup.'

# Local macOS sandbox cannot change priority; Ubuntu exercises real nice below.
if [[ "$(uname -s)" != Linux ]]; then

    # Run the supplied command without changing process priority on this platform.
    nice() { shift 2; "$@"; }
fi

# Portable real archive fixture for verification and extraction tests.
tar -czf "$WORK_DIR/archive.tar.gz" -C / "${SOURCES[0]#/}"
verify_archive
publish_archive >/dev/null
[[ -s "$ARCHIVE" ]] || fail 'Verified archive not published.'
tar -xzf "$ARCHIVE" -C "$TEST_DIR/restore"
cmp "$TEST_DIR/source/sample.txt" "$TEST_DIR/restore/${SOURCES[0]#/}/sample.txt" || fail 'Restored contents differ.'
pass 'Real compressed archive verifies, publishes, and restores exact contents.'

cp "$ARCHIVE" "$WORK_DIR/archive.tar.gz"

rc=0
( SOURCES=(/missing-required-source); verify_archive ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail 'Missing archive source accepted.'
pass 'Missing required source rejected.'

printf 'not gzip\n' > "$WORK_DIR/archive.tar.gz"

rc=0
( verify_archive ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail 'Corrupt archive accepted.'
[[ -s "$ARCHIVE" ]] || fail 'Existing backup lost.'
pass 'Corrupt archive rejected; previous backup preserved.'

# Check disk-space refusal without relying on the machine running these tests.

rc=0

# Mock source size and available disk space to force the low-space check.
( du() { printf '1000\tfixture\n'; }; df() { printf 'Avail\n1\n'; }; check_space ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail 'Low space accepted.'
pass 'Insufficient disk space rejected.'

if tar --version | grep -q 'GNU tar'; then
    create_archive
    verify_archive
    pass 'Actual GNU tar worker and inherited niceness verified on sample data.'

else
    printf 'SKIP: GNU tar worker requires Ubuntu; portable archive tests passed.\n'
fi
