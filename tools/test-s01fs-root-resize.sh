#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/kvmapp/system/init.d/S01fs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nanokvm-s01fs-root.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

fail() {
        echo "FAIL: $*" >&2
        exit 1
}

assert_empty() {
        [ ! -s "$1" ] || fail "$1 is not empty: $(cat "$1")"
}

assert_line() {
        expected=$1
        file=$2
        [ -f "$file" ] || fail "missing $file"
        actual=$(cat "$file")
        [ "$actual" = "$expected" ] || fail "$file: expected '$expected', got '$actual'"
}

new_case() {
        name=$1
        CASE_DIR="$TMP_ROOT/$name"
        mkdir -p "$CASE_DIR/bin"
        START_FILE="$CASE_DIR/start"
        SIZE_FILE="$CASE_DIR/size"
        MARKER="$CASE_DIR/root-ready"
        PARTED_LOG="$CASE_DIR/parted.log"
        RESIZE_LOG="$CASE_DIR/resize.log"
        : > "$PARTED_LOG"
        : > "$RESIZE_LOG"

        cat > "$CASE_DIR/bin/parted" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$PARTED_LOG'
exit \${PARTED_RESULT:-0}
EOF
        cat > "$CASE_DIR/bin/resize2fs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$RESIZE_LOG'
exit \${RESIZE_RESULT:-0}
EOF
        chmod +x "$CASE_DIR/bin/parted" "$CASE_DIR/bin/resize2fs"
}

run_prepare() (
        NANOKVM_DISK=/dev/testdisk
        NANOKVM_ROOT_PART=/dev/testdisk2
        NANOKVM_ROOT_START_FILE=$START_FILE
        NANOKVM_ROOT_SIZE_FILE=$SIZE_FILE
        NANOKVM_ROOT_READY_MARKER=$MARKER
        NANOKVM_ROOT_END_SECTOR=16000000
        NANOKVM_PARTED=$CASE_DIR/bin/parted
        NANOKVM_RESIZE2FS=$CASE_DIR/bin/resize2fs
        export NANOKVM_DISK NANOKVM_ROOT_PART NANOKVM_ROOT_START_FILE
        export NANOKVM_ROOT_SIZE_FILE NANOKVM_ROOT_READY_MARKER
        export NANOKVM_ROOT_END_SECTOR NANOKVM_PARTED NANOKVM_RESIZE2FS
        export PARTED_RESULT RESIZE_RESULT
        set --
        # shellcheck disable=SC1090
        . "$SCRIPT"
        prepare_root_filesystem
)

# An already prepared device must perform no partition or filesystem writes.
new_case already_ready
printf '32769\n' > "$START_FILE"
printf '15967232\n' > "$SIZE_FILE"
printf '16000000\n' > "$MARKER"
run_prepare
assert_empty "$PARTED_LOG"
assert_empty "$RESIZE_LOG"

# Existing devices without the new marker verify/resize ext4 once, but do not
# rewrite the MBR when the partition already ends at the target sector.
new_case migration
printf '32769\n' > "$START_FILE"
printf '15967232\n' > "$SIZE_FILE"
run_prepare
assert_empty "$PARTED_LOG"
assert_line '/dev/testdisk2' "$RESIZE_LOG"
assert_line '16000000' "$MARKER"

# A freshly flashed official image grows p2 directly from sector 3178496 to
# 16000000, then synchronously expands ext4 and records completion.
new_case fresh_image
printf '32769\n' > "$START_FILE"
printf '3145728\n' > "$SIZE_FILE"
run_prepare
assert_line '-s /dev/testdisk unit s resizepart 2 16000000s' "$PARTED_LOG"
assert_line '/dev/testdisk2' "$RESIZE_LOG"
assert_line '16000000' "$MARKER"

# A stale marker cannot suppress recovery after geometry changes.
new_case stale_marker
printf '32769\n' > "$START_FILE"
printf '3145728\n' > "$SIZE_FILE"
printf '16000000\n' > "$MARKER"
run_prepare
assert_line '-s /dev/testdisk unit s resizepart 2 16000000s' "$PARTED_LOG"
assert_line '/dev/testdisk2' "$RESIZE_LOG"
assert_line '16000000' "$MARKER"

# A legacy interrupted boot can leave p2 larger than the intended boundary.
# It is safe to grow ext4 into that space, but never safe to shrink the live
# partition around it. Record the observed geometry after resize2fs succeeds.
new_case oversized_partition
printf '32769\n' > "$START_FILE"
printf '19967232\n' > "$SIZE_FILE"
printf '16000000\n' > "$MARKER"
run_prepare
assert_empty "$PARTED_LOG"
assert_line '/dev/testdisk2' "$RESIZE_LOG"
assert_line '20000000' "$MARKER"

# Once the oversized geometry has been verified, later boots are read-only.
: > "$RESIZE_LOG"
run_prepare
assert_empty "$PARTED_LOG"
assert_empty "$RESIZE_LOG"

# Never claim completion if either destructive step fails.
new_case parted_failure
printf '32769\n' > "$START_FILE"
printf '3145728\n' > "$SIZE_FILE"
PARTED_RESULT=1
if run_prepare; then fail 'parted failure was ignored'; fi
assert_empty "$RESIZE_LOG"
[ ! -e "$MARKER" ] || fail 'parted failure left ready marker'

new_case resize_failure
printf '32769\n' > "$START_FILE"
printf '15967232\n' > "$SIZE_FILE"
RESIZE_RESULT=1
if run_prepare; then fail 'resize2fs failure was ignored'; fi
assert_empty "$PARTED_LOG"
[ ! -e "$MARKER" ] || fail 'resize2fs failure left ready marker'

# Invalid geometry is a safe failure: no command is attempted.
new_case invalid_geometry
printf 'not-a-number\n' > "$START_FILE"
printf '15967232\n' > "$SIZE_FILE"
if run_prepare; then fail 'invalid geometry was accepted'; fi
assert_empty "$PARTED_LOG"
assert_empty "$RESIZE_LOG"

echo 'S01fs root-resize tests passed'
