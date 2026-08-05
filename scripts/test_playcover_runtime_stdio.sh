#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d /tmp/ios-use-play-stdio.XXXXXX)"
HARNESS="$TEMP_ROOT/runtime-stdio-harness"

cleanup() {
  if [[ "$TEMP_ROOT" == /tmp/ios-use-play-stdio.* ]]; then
    /bin/rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

xcrun clang \
  -std=gnu17 \
  -Wall \
  -Wextra \
  -Werror \
  -DIOS_USE_PLAY_RUNTIME_STDIO_STANDALONE=1 \
  -I "$ROOT_DIR/playcover-runtime" \
  "$ROOT_DIR/playcover-runtime/IOSUsePlayRuntimeStdio.c" \
  "$ROOT_DIR/playcover-runtime/tests/RuntimeStdioHarness.c" \
  -o "$HARNESS"

run_capture() {
  local path="$1"
  local device="$2"
  local inode="$3"
  local token="$4"
  IOS_USE_PLAY_STDIO_LOG=1 \
  IOS_USE_PLAY_STDIO_LOG_PATH="$path" \
  IOS_USE_PLAY_STDIO_LOG_DEVICE="$device" \
  IOS_USE_PLAY_STDIO_LOG_INODE="$inode" \
  IOS_USE_PLAY_STDIO_TEST_TOKEN="$token" \
    "$HARNESS"
}

expect_rejected() {
  local name="$1"
  shift
  set +e
  "$@" >"$TEMP_ROOT/$name.stdout" 2>"$TEMP_ROOT/$name.stderr"
  local status=$?
  set -e
  if [[ "$status" -ne 78 ]]; then
    echo "[runtime-stdio] $name: expected exit 78, got $status" >&2
    exit 1
  fi
  if ! rg -q 'stdio capture failed:' "$TEMP_ROOT/$name.stderr"; then
    echo "[runtime-stdio] $name: missing fail-closed diagnostic" >&2
    exit 1
  fi
}

valid_log="$TEMP_ROOT/valid.log"
: >"$valid_log"
chmod 600 "$valid_log"
valid_device="$(stat -f '%d' "$valid_log")"
valid_inode="$(stat -f '%i' "$valid_log")"
run_capture \
  "$valid_log" \
  "$valid_device" \
  "$valid_inode" \
  "valid-$valid_inode"
if [[ "$(stat -f '%Lp' "$valid_log")" != "600" ]]; then
  echo "[runtime-stdio] valid capture changed the 0600 mode" >&2
  exit 1
fi
for marker in \
  '[ios-use-play] stdio capture ready' \
  "fixture-stdout:valid-$valid_inode" \
  "fixture-stderr:valid-$valid_inode"; do
  if ! rg -Fq "$marker" "$valid_log"; then
    echo "[runtime-stdio] valid capture missing marker: $marker" >&2
    exit 1
  fi
done

no_flag_stdout="$TEMP_ROOT/no-flag.stdout"
no_flag_stderr="$TEMP_ROOT/no-flag.stderr"
IOS_USE_PLAY_STDIO_LOG_PATH="/untrusted/path" \
IOS_USE_PLAY_STDIO_LOG_DEVICE="not-a-device" \
IOS_USE_PLAY_STDIO_LOG_INODE="not-an-inode" \
IOS_USE_PLAY_STDIO_TEST_TOKEN="no-flag" \
  "$HARNESS" >"$no_flag_stdout" 2>"$no_flag_stderr"
rg -Fxq 'fixture-stdout:no-flag' "$no_flag_stdout"
rg -Fxq 'fixture-stderr:no-flag' "$no_flag_stderr"

expect_rejected missing_identity \
  env \
    IOS_USE_PLAY_STDIO_LOG=1 \
    IOS_USE_PLAY_STDIO_LOG_PATH="$valid_log" \
    "$HARNESS"

replacement_log="$TEMP_ROOT/replacement.log"
: >"$replacement_log"
chmod 600 "$replacement_log"
expect_rejected replaced_inode \
  run_capture \
    "$replacement_log" \
    "$valid_device" \
    "$valid_inode" \
    "replacement"

symlink_log="$TEMP_ROOT/symlink.log"
ln -s "$valid_log" "$symlink_log"
expect_rejected symlink_leaf \
  run_capture \
    "$symlink_log" \
    "$valid_device" \
    "$valid_inode" \
    "symlink"

wide_log="$TEMP_ROOT/wide.log"
: >"$wide_log"
chmod 644 "$wide_log"
wide_device="$(stat -f '%d' "$wide_log")"
wide_inode="$(stat -f '%i' "$wide_log")"
expect_rejected broad_mode \
  run_capture \
    "$wide_log" \
    "$wide_device" \
    "$wide_inode" \
    "broad-mode"

linked_log="$TEMP_ROOT/linked.log"
: >"$linked_log"
chmod 600 "$linked_log"
ln "$linked_log" "$TEMP_ROOT/linked-copy.log"
linked_device="$(stat -f '%d' "$linked_log")"
linked_inode="$(stat -f '%i' "$linked_log")"
expect_rejected multiple_links \
  run_capture \
    "$linked_log" \
    "$linked_device" \
    "$linked_inode" \
    "multiple-links"

echo "[runtime-stdio] PASS"
