#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/kvmapp/system/init.d/S01fs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nanokvm-s01fs-data.XXXXXX")
REAL_DD=$(command -v dd)
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

fail() {
        echo "FAIL: $*" >&2
        exit 1
}

assert_exists() {
        [ -e "$1" ] || fail "missing $1"
}

assert_missing() {
        [ ! -e "$1" ] || fail "unexpected $1"
}

assert_log() {
        grep -Fq "$1" "$LOG" || fail "log does not contain: $1"
}

assert_no_log() {
        ! grep -Fq "$1" "$LOG" || fail "log unexpectedly contains: $1"
}

new_case() {
        name=$1
        CASE_DIR="$TMP_ROOT/$name"
        BIN="$CASE_DIR/bin"
        BOOT="$CASE_DIR/boot"
        DATA="$CASE_DIR/data"
        DEV="$CASE_DIR/dev"
        ETC="$CASE_DIR/etc"
        LOG="$CASE_DIR/log"
        MOUNTS="$CASE_DIR/mounts"
        mkdir -p "$BIN" "$BOOT" "$DATA" "$DEV" "$ETC"
        : > "$LOG"
        : > "$MOUNTS"
        : > "$BOOT/usb.disk0"

        cat > "$BIN/parted" <<'EOF'
#!/bin/sh
printf 'parted %s\n' "$*" >> "$NANOKVM_TEST_LOG"
if [ "${NANOKVM_TEST_PARTED_FAIL:-0}" = "1" ]; then
        exit 1
fi
if [ "${NANOKVM_TEST_PARTITION_DELAYED:-0}" != "1" ] && \
        [ "${NANOKVM_TEST_PARTITION_MISSING:-0}" != "1" ]; then
        : > "$NANOKVM_DATA_PART"
fi
EOF

        cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
if [ "${NANOKVM_TEST_PARTITION_DELAYED:-0}" = "1" ] && [ ! -e "$NANOKVM_DATA_PART" ]; then
        : > "$NANOKVM_DATA_PART"
fi
EOF

        cat > "$BIN/mkfs.exfat" <<'EOF'
#!/bin/sh
printf 'mkfs.exfat %s\n' "$*" >> "$NANOKVM_TEST_LOG"
if [ "${NANOKVM_TEST_MKFS_FAIL:-0}" = "1" ]; then
        exit 1
fi
: > "$1.hasfs"
EOF

        cat > "$BIN/blkid" <<'EOF'
#!/bin/sh
printf 'blkid %s\n' "$*" >> "$NANOKVM_TEST_LOG"
if [ -e "$1.hasfs" ]; then
        printf '%s: TYPE="exfat"\n' "$1"
fi
EOF

cat > "$BIN/mount" <<'EOF'
#!/bin/sh
printf 'mount %s\n' "$*" >> "$NANOKVM_TEST_LOG"
if [ "${NANOKVM_TEST_MOUNT_FAIL:-0}" = "1" ]; then
        exit 1
fi
printf '%s %s exfat rw 0 0\n' "$1" "$2" >> "$NANOKVM_MOUNTS_FILE"
EOF

        cat > "$BIN/dd" <<EOF
#!/bin/sh
printf 'dd %s\n' "\$*" >> "\$NANOKVM_TEST_LOG"
exec "$REAL_DD" "\$@"
EOF
        chmod +x "$BIN/parted" "$BIN/sleep" "$BIN/mkfs.exfat" \
                "$BIN/blkid" "$BIN/mount" "$BIN/dd"

        NANOKVM_DISK="$DEV/mmcblk0"
        NANOKVM_DATA_PART="$DEV/mmcblk0p3"
        NANOKVM_BOOT_DIR="$BOOT"
        NANOKVM_DATA_DIR="$DATA"
        NANOKVM_DISK0_MARKER="$ETC/kvm.disk0"
        NANOKVM_DATA_FORMAT_PENDING="$ETC/kvm.disk0.formatting"
        NANOKVM_TEST_LOG="$LOG"
        NANOKVM_MOUNTS_FILE="$MOUNTS"
        PATH="$BIN:$PATH"
        export NANOKVM_DISK NANOKVM_DATA_PART NANOKVM_BOOT_DIR
        export NANOKVM_DATA_DIR NANOKVM_DISK0_MARKER
        export NANOKVM_DATA_FORMAT_PENDING NANOKVM_TEST_LOG PATH
        export NANOKVM_MOUNTS_FILE
        unset NANOKVM_TEST_PARTED_FAIL NANOKVM_TEST_PARTITION_DELAYED
        unset NANOKVM_TEST_PARTITION_MISSING NANOKVM_TEST_MKFS_FAIL
        unset NANOKVM_TEST_MOUNT_FAIL
}

run_prepare_data() (
        set --
        # shellcheck disable=SC1090
        . "$SCRIPT"
        prepare_data_filesystem
)

new_case new_partition
run_prepare_data
assert_exists "$NANOKVM_DATA_PART.hasfs"
assert_exists "$NANOKVM_DISK0_MARKER"
assert_missing "$NANOKVM_DATA_FORMAT_PENDING"
assert_log "parted -s $NANOKVM_DISK mkpart primary 8193MB 100%"
assert_log "mkfs.exfat $NANOKVM_DATA_PART"
assert_log "mount $NANOKVM_DATA_PART $NANOKVM_DATA_DIR"

new_case delayed_device
NANOKVM_TEST_PARTITION_DELAYED=1
export NANOKVM_TEST_PARTITION_DELAYED
run_prepare_data
assert_exists "$NANOKVM_DATA_PART.hasfs"
assert_exists "$NANOKVM_DISK0_MARKER"
assert_missing "$NANOKVM_DATA_FORMAT_PENDING"

new_case device_never_appears
NANOKVM_TEST_PARTITION_MISSING=1
export NANOKVM_TEST_PARTITION_MISSING
run_prepare_data
assert_missing "$NANOKVM_DATA_PART"
assert_exists "$NANOKVM_DATA_FORMAT_PENDING"
assert_missing "$NANOKVM_DISK0_MARKER"
assert_no_log "mkfs.exfat $NANOKVM_DATA_PART"

new_case mkfs_failure
: > "$NANOKVM_DATA_PART"
: > "$NANOKVM_DATA_FORMAT_PENDING"
: > "$NANOKVM_DISK0_MARKER"
NANOKVM_TEST_MKFS_FAIL=1
export NANOKVM_TEST_MKFS_FAIL
run_prepare_data
assert_exists "$NANOKVM_DATA_FORMAT_PENDING"
assert_missing "$NANOKVM_DISK0_MARKER"
assert_log "mkfs.exfat $NANOKVM_DATA_PART"
assert_no_log "mount $NANOKVM_DATA_PART $NANOKVM_DATA_DIR"

new_case mount_failure
: > "$NANOKVM_DATA_PART"
: > "$NANOKVM_DATA_FORMAT_PENDING"
: > "$NANOKVM_DISK0_MARKER"
NANOKVM_TEST_MOUNT_FAIL=1
export NANOKVM_TEST_MOUNT_FAIL
run_prepare_data
assert_exists "$NANOKVM_DATA_PART.hasfs"
assert_missing "$NANOKVM_DATA_FORMAT_PENDING"
assert_missing "$NANOKVM_DISK0_MARKER"

new_case existing_filesystem
: > "$NANOKVM_DATA_PART"
: > "$NANOKVM_DATA_PART.hasfs"
run_prepare_data
assert_exists "$NANOKVM_DISK0_MARKER"
assert_log "blkid $NANOKVM_DATA_PART"
assert_log "mount $NANOKVM_DATA_PART $NANOKVM_DATA_DIR"
assert_no_log "mkfs.exfat $NANOKVM_DATA_PART"

# A second start is read-only for an already mounted data partition.
: > "$LOG"
run_prepare_data
assert_exists "$NANOKVM_DISK0_MARKER"
assert_no_log "mount $NANOKVM_DATA_PART $NANOKVM_DATA_DIR"
assert_no_log "mkfs.exfat $NANOKVM_DATA_PART"

new_case unknown_partition
printf 'user data\n' > "$NANOKVM_DATA_PART"
: > "$NANOKVM_DISK0_MARKER"
run_prepare_data
assert_missing "$NANOKVM_DISK0_MARKER"
assert_no_log "mkfs.exfat $NANOKVM_DATA_PART"
assert_no_log "mount $NANOKVM_DATA_PART $NANOKVM_DATA_DIR"

new_case empty_legacy_partition
: > "$NANOKVM_DATA_PART"
: > "$NANOKVM_DISK0_MARKER"
run_prepare_data
assert_exists "$NANOKVM_DATA_PART.hasfs"
assert_exists "$NANOKVM_DISK0_MARKER"
assert_log "dd if=$NANOKVM_DATA_PART"
assert_log "mkfs.exfat $NANOKVM_DATA_PART"

new_case custom_backing_file
printf '%s\n' "$CASE_DIR/custom.img" > "$BOOT/usb.disk0"
run_prepare_data
assert_missing "$NANOKVM_DATA_PART"
assert_missing "$NANOKVM_DATA_FORMAT_PENDING"
assert_no_log "parted -s $NANOKVM_DISK mkpart primary 8193MB 100%"

echo 'S01fs data-lifecycle tests passed'
