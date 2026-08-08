#!/bin/bash
set -euo pipefail
umask 077

fail_case() {
  printf '%s FAIL\n' "$1" >&2
  exit 1
}

PREPARED_APP=""
PLAYCHAIN_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepared-app)
      [[ -z "$PREPARED_APP" && $# -ge 2 ]] ||
        fail_case "PCAP-CONFIG-ARGS"
      PREPARED_APP="$2"
      shift 2
      ;;
    --playchain-root)
      [[ -z "$PLAYCHAIN_ROOT" && $# -ge 2 ]] ||
        fail_case "PCAP-CONFIG-ARGS"
      PLAYCHAIN_ROOT="$2"
      shift 2
      ;;
    *)
      fail_case "PCAP-CONFIG-ARGS"
      ;;
  esac
done

[[ -n "$PREPARED_APP" && -n "$PLAYCHAIN_ROOT" ]] ||
  fail_case "PCAP-CONFIG-ARGS"
[[ "$PREPARED_APP" == /* && "$PLAYCHAIN_ROOT" == /* ]] ||
  fail_case "PCAP-CONFIG-ABSOLUTE"
[[ "$(/usr/bin/uname -s)" == "Darwin" ]] ||
  fail_case "PCAP-CONFIG-HOST"

CURRENT_UID="$EUID"
SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
GLOBAL_STATE_GUARD="$SCRIPT_DIR/test_playcover_global_state_guard.sh"
if [[ ! -f "$GLOBAL_STATE_GUARD" || -L "$GLOBAL_STATE_GUARD" ]]; then
  printf '%s\n' \
    "PCAP-CONFIG-GLOBAL-GUARD EX_CONFIG: account-global safety guard unavailable" \
    >&2
  exit 78
fi
# shellcheck source=scripts/test_playcover_global_state_guard.sh
source "$GLOBAL_STATE_GUARD"
playcover_require_disposable_account_contract \
  "playcover-entitlement-capabilities"

canonical_existing() {
  /bin/realpath "$1" 2>/dev/null
}

require_canonical_directory() {
  local path="$1"
  local canonical
  [[ -d "$path" && ! -L "$path" ]] ||
    fail_case "PCAP-CONFIG-DIRECTORY"
  canonical="$(canonical_existing "$path")" ||
    fail_case "PCAP-CONFIG-DIRECTORY"
  [[ "$canonical" == "$path" ]] ||
    fail_case "PCAP-CONFIG-SYMLINK"
}

require_owner_directory_700() {
  local path="$1"
  local owner
  local mode
  require_canonical_directory "$path"
  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" ||
    fail_case "PCAP-CONFIG-DIRECTORY"
  mode="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null)" ||
    fail_case "PCAP-CONFIG-DIRECTORY"
  [[ "$owner" == "$CURRENT_UID" && "$mode" == "700" ]] ||
    fail_case "PCAP-CONFIG-OWNER-MODE"
}

require_owned_regular_600() {
  local path="$1"
  local owner
  local mode
  local links
  [[ -f "$path" && ! -L "$path" ]] ||
    fail_case "PCAP-HOST-SETUP"
  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" ||
    fail_case "PCAP-HOST-SETUP"
  mode="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null)" ||
    fail_case "PCAP-HOST-SETUP"
  links="$(/usr/bin/stat -f '%l' "$path" 2>/dev/null)" ||
    fail_case "PCAP-HOST-SETUP"
  [[
    "$owner" == "$CURRENT_UID" &&
    "$mode" == "600" &&
    "$links" == "1"
  ]] || fail_case "PCAP-HOST-SETUP"
}

require_owned_socket() {
  local path="$1"
  local owner
  local links
  [[ -S "$path" && ! -L "$path" ]] ||
    fail_case "PCAP-HOST-POSTCONDITIONS"
  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" ||
    fail_case "PCAP-HOST-POSTCONDITIONS"
  links="$(/usr/bin/stat -f '%l' "$path" 2>/dev/null)" ||
    fail_case "PCAP-HOST-POSTCONDITIONS"
  [[ "$owner" == "$CURRENT_UID" && "$links" == "1" ]] ||
    fail_case "PCAP-HOST-POSTCONDITIONS"
}

require_owned_nonwritable_directory() {
  local path="$1"
  local canonical
  local owner
  local mode
  [[ -d "$path" && ! -L "$path" ]] ||
    fail_case "PCAP-CONFIG-PREPARED"
  canonical="$(canonical_existing "$path")" ||
    fail_case "PCAP-CONFIG-PREPARED"
  [[ "$canonical" == "$path" ]] ||
    fail_case "PCAP-CONFIG-SYMLINK"
  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" ||
    fail_case "PCAP-CONFIG-PREPARED"
  mode="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null)" ||
    fail_case "PCAP-CONFIG-PREPARED"
  [[ "$owner" == "$CURRENT_UID" ]] ||
    fail_case "PCAP-CONFIG-OWNER-MODE"
  (( (8#$mode & 0022) == 0 )) ||
    fail_case "PCAP-CONFIG-OWNER-MODE"
}

require_owned_regular() {
  local path="$1"
  local canonical
  local owner
  [[ -f "$path" && ! -L "$path" ]] ||
    fail_case "PCAP-CONFIG-PREPARED"
  canonical="$(canonical_existing "$path")" ||
    fail_case "PCAP-CONFIG-PREPARED"
  [[ "$canonical" == "$path" ]] ||
    fail_case "PCAP-CONFIG-SYMLINK"
  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" ||
    fail_case "PCAP-CONFIG-PREPARED"
  [[ "$owner" == "$CURRENT_UID" ]] ||
    fail_case "PCAP-CONFIG-OWNER-MODE"
}

require_owner_directory_700 "$PLAYCOVER_ACCOUNT_CACHE_ROOT"
PREPARED_ROOT="$PLAYCOVER_APPS_ROOT"
KNOWN_HOMES_DIR="$PLAYCOVER_KNOWN_HOMES_ROOT"
GLOBAL_LOCKS_DIR="$PLAYCOVER_LOCKS_ROOT"
SOCKET_ROOT="$PLAYCOVER_SOCKET_ROOT"
PLAYCHAIN_DIR="$PLAYCHAIN_ROOT"
LOGS_DIR="$PLAYCHAIN_ROOT"

for directory in \
  "$PREPARED_ROOT" \
  "$KNOWN_HOMES_DIR" \
  "$GLOBAL_LOCKS_DIR" \
  "$SOCKET_ROOT" \
  "$PLAYCHAIN_DIR"; do
  require_owner_directory_700 "$directory"
done

[[ "$PLAYCHAIN_ROOT" == "$PLAYCOVER_PLAYCHAIN_ROOT" ]] ||
  fail_case "PCAP-CONFIG-PLAYCHAIN"

require_owned_nonwritable_directory "$PREPARED_APP"
[[ "$PREPARED_APP" == *.app ]] ||
  fail_case "PCAP-CONFIG-PREPARED"

SLOT_DIR="${PREPARED_APP%/*}"
BUNDLE_ID="${SLOT_DIR##*/}"
[[
  "${SLOT_DIR%/*}" == "$PREPARED_ROOT" &&
  -n "$BUNDLE_ID" &&
  "$BUNDLE_ID" != "." &&
  "$BUNDLE_ID" != ".." &&
  "$BUNDLE_ID" != */*
]] || fail_case "PCAP-CONFIG-PREPARED"
require_owner_directory_700 "$SLOT_DIR"
SLOT_METADATA="$SLOT_DIR/slot.json"
require_owned_regular_600 "$SLOT_METADATA"
[[ "$(/usr/bin/jq -er '.bundleIdentifier' "$SLOT_METADATA")" == "$BUNDLE_ID" ]] ||
  fail_case "PCAP-CONFIG-PREPARED"
[[ "$(/usr/bin/jq -er '.appRelativePath' "$SLOT_METADATA")" == "${PREPARED_APP##*/}" ]] ||
  fail_case "PCAP-CONFIG-PREPARED"

/usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  --verbose=2 \
  "$PREPARED_APP" >/dev/null 2>&1 ||
  fail_case "PCAP-PREPARED-SIGNATURE"

IOS_INFO_PLIST="$PREPARED_APP/Info.plist"
MAC_INFO_PLIST="$PREPARED_APP/Contents/Info.plist"
if [[
  -f "$IOS_INFO_PLIST" &&
  ! -L "$IOS_INFO_PLIST" &&
  ! -e "$MAC_INFO_PLIST" &&
  ! -L "$MAC_INFO_PLIST"
]]; then
  INFO_PLIST="$IOS_INFO_PLIST"
  EXECUTABLE_ROOT="$PREPARED_APP"
elif [[
  -f "$MAC_INFO_PLIST" &&
  ! -L "$MAC_INFO_PLIST" &&
  ! -e "$IOS_INFO_PLIST" &&
  ! -L "$IOS_INFO_PLIST"
]]; then
  INFO_PLIST="$MAC_INFO_PLIST"
  EXECUTABLE_ROOT="$PREPARED_APP/Contents/MacOS"
else
  fail_case "PCAP-CONFIG-PREPARED"
fi
require_owned_regular "$INFO_PLIST"
EXECUTABLE_NAME="$(
  /usr/bin/plutil \
    -extract CFBundleExecutable raw \
    -o - \
    "$INFO_PLIST" 2>/dev/null
)" || fail_case "PCAP-CONFIG-PREPARED"
case "$EXECUTABLE_NAME" in
  ""|"."|".."|*/*|*$'\n'*|*$'\r'*)
    fail_case "PCAP-CONFIG-PREPARED"
    ;;
esac
MAIN_EXECUTABLE="$EXECUTABLE_ROOT/$EXECUTABLE_NAME"
require_owned_regular "$MAIN_EXECUTABLE"
[[ -x "$MAIN_EXECUTABLE" ]] ||
  fail_case "PCAP-CONFIG-PREPARED"
/usr/bin/codesign \
  --verify \
  --strict \
  --verbose=2 \
  "$MAIN_EXECUTABLE" >/dev/null 2>&1 ||
  fail_case "PCAP-PREPARED-SIGNATURE"
printf '%s PASS\n' "PCAP-PREPARED-SIGNATURE"

AUDIT_TEMP_ROOT="$(
  /usr/bin/mktemp -d \
    /private/tmp/ios-use-pcap.XXXXXX 2>/dev/null
)" || fail_case "PCAP-TEMP"
/bin/chmod 700 "$AUDIT_TEMP_ROOT" >/dev/null 2>&1 ||
  fail_case "PCAP-TEMP"
case "$AUDIT_TEMP_ROOT/" in
  "$PLAYCOVER_ACCOUNT_HOME/"*|\
  "$PLAYCOVER_ACCOUNT_CACHE_ROOT/"*|\
  "$PLAYCOVER_PLAYCHAIN_ROOT/"*|\
  "$PLAYCOVER_SOCKET_ROOT/"*)
    fail_case "PCAP-TEMP"
    ;;
esac
printf 'PCAP-EVIDENCE-ROOT %s\n' "$AUDIT_TEMP_ROOT"

PROBE_SOURCE="$(
  cd "$(dirname "$0")" &&
    /bin/pwd -P
)/playcover_entitlement_capability_probe.c"
[[ -f "$PROBE_SOURCE" && ! -L "$PROBE_SOURCE" ]] ||
  fail_case "PCAP-PROBE-BUILD"
UNSIGNED_PROBE="$AUDIT_TEMP_ROOT/probe-unsigned"
PROBE_APP="$AUDIT_TEMP_ROOT/IOSUseCapabilityProbe.app"
PROBE_CONTENTS="$PROBE_APP/Contents"
PROBE_MACOS="$PROBE_CONTENTS/MacOS"
PROBE_INFO="$PROBE_CONTENTS/Info.plist"
SIGNED_PROBE="$PROBE_MACOS/IOSUseCapabilityProbe"
ORIGINAL_ENTITLEMENTS="$AUDIT_TEMP_ROOT/original-entitlements.plist"
PROBE_ENTITLEMENTS="$AUDIT_TEMP_ROOT/probe-entitlements.plist"
CLANG_LOG="$AUDIT_TEMP_ROOT/clang.log"
PREPARED_ENTITLEMENTS_LOG="$AUDIT_TEMP_ROOT/prepared-entitlements.log"
PROBE_SIGN_STDOUT="$AUDIT_TEMP_ROOT/probe-sign.stdout"
PROBE_SIGN_STDERR="$AUDIT_TEMP_ROOT/probe-sign.stderr"
PROBE_ENTITLEMENTS_LOG="$AUDIT_TEMP_ROOT/probe-entitlements.log"

/usr/bin/xcrun clang \
  -std=c17 \
  -Wall \
  -Wextra \
  -Werror \
  "$PROBE_SOURCE" \
  -framework CoreFoundation \
  -lsqlite3 \
  -o "$UNSIGNED_PROBE" \
  >"$CLANG_LOG" 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/bin/mkdir -p "$PROBE_MACOS" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/bin/cp "$UNSIGNED_PROBE" "$SIGNED_PROBE" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/usr/bin/plutil -create xml1 "$PROBE_INFO" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/usr/bin/plutil \
  -insert CFBundleExecutable \
  -string "IOSUseCapabilityProbe" \
  "$PROBE_INFO" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/usr/bin/plutil \
  -insert CFBundleIdentifier \
  -string "com.iosuse.playcover.capability-probe" \
  "$PROBE_INFO" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/usr/bin/plutil \
  -insert CFBundleInfoDictionaryVersion \
  -string "6.0" \
  "$PROBE_INFO" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/usr/bin/plutil \
  -insert CFBundleName \
  -string "IOSUseCapabilityProbe" \
  "$PROBE_INFO" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/usr/bin/plutil \
  -insert CFBundlePackageType \
  -string "APPL" \
  "$PROBE_INFO" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/usr/bin/plutil \
  -insert CFBundleVersion \
  -string "1" \
  "$PROBE_INFO" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"
/usr/bin/plutil \
  -insert LSBackgroundOnly \
  -bool true \
  "$PROBE_INFO" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-BUILD"

/usr/bin/codesign \
  --display \
  --entitlements - \
  --xml \
  "$MAIN_EXECUTABLE" \
  >"$ORIGINAL_ENTITLEMENTS" \
  2>"$PREPARED_ENTITLEMENTS_LOG" ||
  fail_case "PCAP-ENTITLEMENTS-EXPORT"
/usr/bin/plutil -lint "$ORIGINAL_ENTITLEMENTS" >/dev/null 2>&1 ||
  fail_case "PCAP-ENTITLEMENTS-EXPORT"

/usr/bin/codesign \
  --force \
  --sign - \
  --entitlements "$ORIGINAL_ENTITLEMENTS" \
  --generate-entitlement-der \
  "$PROBE_APP" \
  >"$PROBE_SIGN_STDOUT" \
  2>"$PROBE_SIGN_STDERR" ||
  fail_case "PCAP-PROBE-SIGNATURE"
/usr/bin/codesign \
  --verify \
  --strict \
  --verbose=2 \
  "$PROBE_APP" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-SIGNATURE"
/usr/bin/codesign \
  --verify \
  --strict \
  --verbose=2 \
  "$SIGNED_PROBE" >/dev/null 2>&1 ||
  fail_case "PCAP-PROBE-SIGNATURE"
/usr/bin/codesign \
  --display \
  --entitlements - \
  --xml \
  "$SIGNED_PROBE" \
  >"$PROBE_ENTITLEMENTS" \
  2>"$PROBE_ENTITLEMENTS_LOG" ||
  fail_case "PCAP-PROBE-SIGNATURE"
"$UNSIGNED_PROBE" \
  compare-entitlements \
  "$ORIGINAL_ENTITLEMENTS" \
  "$PROBE_ENTITLEMENTS" ||
  fail_case "PCAP-ENTITLEMENTS-EQUAL"
printf '%s PASS\n' "PCAP-PROBE-SIGNATURE"

SOCKET_AUDIT_DIR="$(
  /usr/bin/mktemp -d "$SOCKET_ROOT/.pcap-audit.XXXXXX" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
LOGS_AUDIT_DIR="$(
  /usr/bin/mktemp -d "$LOGS_DIR/.pcap-audit.XXXXXX" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
PLAYCHAIN_AUDIT_DIR="$(
  /usr/bin/mktemp -d "$PLAYCHAIN_DIR/.pcap-audit.XXXXXX" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
STATE_AUDIT_DIR="$(
  /usr/bin/mktemp -d "$AUDIT_TEMP_ROOT/denied-state.XXXXXX" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
PREPARED_AUDIT_DIR="$(
  /usr/bin/mktemp -d "$AUDIT_TEMP_ROOT/denied-prepared.XXXXXX" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
/bin/chmod 700 \
  "$SOCKET_AUDIT_DIR" \
  "$LOGS_AUDIT_DIR" \
  "$PLAYCHAIN_AUDIT_DIR" \
  "$STATE_AUDIT_DIR" \
  "$PREPARED_AUDIT_DIR" >/dev/null 2>&1 ||
  fail_case "PCAP-HOST-SETUP"
for audit_directory in \
  "$SOCKET_AUDIT_DIR" \
  "$LOGS_AUDIT_DIR" \
  "$PLAYCHAIN_AUDIT_DIR" \
  "$STATE_AUDIT_DIR" \
  "$PREPARED_AUDIT_DIR"; do
  require_owner_directory_700 "$audit_directory"
done

RUN_FILE="$SOCKET_AUDIT_DIR/file"
RUN_SOCKET="$SOCKET_AUDIT_DIR/run.sock"
DATABASE="$PLAYCHAIN_AUDIT_DIR/capability.sqlite3"
STATE_CREATE="$STATE_AUDIT_DIR/create"
PREPARED_CREATE="$PREPARED_AUDIT_DIR/create"
LOGS_SOCKET_LINK="$SOCKET_AUDIT_DIR/logs-link"
PLAYCHAIN_SOCKET_LINK="$SOCKET_AUDIT_DIR/playchain-link"
LOGS_SOCKET="$LOGS_SOCKET_LINK/bind.sock"
PLAYCHAIN_SOCKET="$PLAYCHAIN_SOCKET_LINK/bind.sock"
ESCAPE_LINK="$SOCKET_AUDIT_DIR/escape"
for absent in \
  "$RUN_FILE" \
  "$RUN_SOCKET" \
  "$DATABASE" \
  "$DATABASE-wal" \
  "$DATABASE-shm" \
  "$DATABASE-journal" \
  "$STATE_CREATE" \
  "$PREPARED_CREATE" \
  "$LOGS_SOCKET_LINK" \
  "$PLAYCHAIN_SOCKET_LINK" \
  "$LOGS_SOCKET" \
  "$PLAYCHAIN_SOCKET" \
  "$ESCAPE_LINK"; do
  [[ ! -e "$absent" && ! -L "$absent" ]] ||
    fail_case "PCAP-HOST-SETUP"
done
[[
  ${#RUN_SOCKET} -lt 104 &&
  ${#LOGS_SOCKET} -lt 104 &&
  ${#PLAYCHAIN_SOCKET} -lt 104
]] || fail_case "PCAP-CONFIG-SOCKET-LENGTH"

STATE_SENTINEL="$(
  /usr/bin/mktemp \
    "$STATE_AUDIT_DIR/sentinel.XXXXXX" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
PREPARED_SENTINEL="$(
  /usr/bin/mktemp \
    "$PREPARED_AUDIT_DIR/sentinel.XXXXXX" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
LOG_FILE="$(
  /usr/bin/mktemp \
    "$LOGS_AUDIT_DIR/log.XXXXXX" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
EXTERNAL_VICTIM="$AUDIT_TEMP_ROOT/external-victim"
STATE_EXPECTED="$AUDIT_TEMP_ROOT/state-expected"
PREPARED_EXPECTED="$AUDIT_TEMP_ROOT/prepared-expected"
LOG_EXPECTED="$AUDIT_TEMP_ROOT/log-expected"
VICTIM_EXPECTED="$AUDIT_TEMP_ROOT/victim-expected"

printf '%s\n%s\n' \
  "state-host-read" \
  "state-host-write" >"$STATE_SENTINEL"
printf '%s\n%s\n' \
  "state-host-read" \
  "state-host-write" >"$STATE_EXPECTED"
printf '%s\n%s\n' \
  "prepared-host-read" \
  "prepared-host-write" >"$PREPARED_SENTINEL"
printf '%s\n%s\n' \
  "prepared-host-read" \
  "prepared-host-write" >"$PREPARED_EXPECTED"
printf '%s\n' "host-log-seed" >"$LOG_FILE"
printf '%s\n%s\n' \
  "host-log-seed" \
  "probe-append" >"$LOG_EXPECTED"
printf '%s\n' "external-victim-unchanged" >"$EXTERNAL_VICTIM"
printf '%s\n' "external-victim-unchanged" >"$VICTIM_EXPECTED"
/bin/chmod 600 \
  "$STATE_SENTINEL" \
  "$PREPARED_SENTINEL" \
  "$LOG_FILE" \
  "$EXTERNAL_VICTIM" >/dev/null 2>&1 ||
  fail_case "PCAP-HOST-SETUP"
require_owned_regular_600 "$STATE_SENTINEL"
require_owned_regular_600 "$PREPARED_SENTINEL"
require_owned_regular_600 "$LOG_FILE"
require_owned_regular_600 "$EXTERNAL_VICTIM"
[[
  -r "$STATE_SENTINEL" &&
  -w "$STATE_SENTINEL" &&
  -r "$PREPARED_SENTINEL" &&
  -w "$PREPARED_SENTINEL"
]] || fail_case "PCAP-HOST-SETUP"
/usr/bin/cmp -s "$STATE_SENTINEL" "$STATE_EXPECTED" ||
  fail_case "PCAP-HOST-SETUP"
/usr/bin/cmp -s "$PREPARED_SENTINEL" "$PREPARED_EXPECTED" ||
  fail_case "PCAP-HOST-SETUP"
/bin/ln -s "$EXTERNAL_VICTIM" "$ESCAPE_LINK" >/dev/null 2>&1 ||
  fail_case "PCAP-HOST-SETUP"
/bin/ln -s "$LOGS_AUDIT_DIR" "$LOGS_SOCKET_LINK" >/dev/null 2>&1 ||
  fail_case "PCAP-HOST-SETUP"
/bin/ln -s \
  "$PLAYCHAIN_AUDIT_DIR" \
  "$PLAYCHAIN_SOCKET_LINK" >/dev/null 2>&1 ||
  fail_case "PCAP-HOST-SETUP"
[[
  -L "$ESCAPE_LINK" &&
  -L "$LOGS_SOCKET_LINK" &&
  -L "$PLAYCHAIN_SOCKET_LINK"
]] ||
  fail_case "PCAP-HOST-SETUP"
/usr/bin/cmp -s "$ESCAPE_LINK" "$VICTIM_EXPECTED" ||
  fail_case "PCAP-HOST-SETUP"
: >>"$ESCAPE_LINK" ||
  fail_case "PCAP-HOST-SETUP"

LOG_DEVICE="$(/usr/bin/stat -f '%d' "$LOG_FILE" 2>/dev/null)" ||
  fail_case "PCAP-HOST-SETUP"
LOG_INODE="$(/usr/bin/stat -f '%i' "$LOG_FILE" 2>/dev/null)" ||
  fail_case "PCAP-HOST-SETUP"
STATE_DEVICE="$(/usr/bin/stat -f '%d' "$STATE_SENTINEL" 2>/dev/null)" ||
  fail_case "PCAP-HOST-SETUP"
STATE_INODE="$(/usr/bin/stat -f '%i' "$STATE_SENTINEL" 2>/dev/null)" ||
  fail_case "PCAP-HOST-SETUP"
PREPARED_DEVICE="$(
  /usr/bin/stat -f '%d' "$PREPARED_SENTINEL" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
PREPARED_INODE="$(
  /usr/bin/stat -f '%i' "$PREPARED_SENTINEL" 2>/dev/null
)" || fail_case "PCAP-HOST-SETUP"
VICTIM_DEVICE="$(/usr/bin/stat -f '%d' "$EXTERNAL_VICTIM" 2>/dev/null)" ||
  fail_case "PCAP-HOST-SETUP"
VICTIM_INODE="$(/usr/bin/stat -f '%i' "$EXTERNAL_VICTIM" 2>/dev/null)" ||
  fail_case "PCAP-HOST-SETUP"
printf '%s PASS\n' "PCAP-HOST-SETUP"

set +e
"$SIGNED_PROBE" run \
  "$RUN_FILE" \
  "$RUN_SOCKET" \
  "$LOG_FILE" \
  "$LOG_DEVICE" \
  "$LOG_INODE" \
  "$DATABASE" \
  "$STATE_SENTINEL" \
  "$STATE_CREATE" \
  "$PREPARED_SENTINEL" \
  "$PREPARED_CREATE" \
  "$LOGS_SOCKET" \
  "$PLAYCHAIN_SOCKET" \
  "$ESCAPE_LINK"
PROBE_STATUS=$?
set -e
[[ "$PROBE_STATUS" -eq 0 ]] ||
  fail_case "PCAP-PROBE-EXEC"

require_owned_regular_600 "$LOG_FILE"
[[
  "$(/usr/bin/stat -f '%d' "$LOG_FILE" 2>/dev/null)" == "$LOG_DEVICE" &&
  "$(/usr/bin/stat -f '%i' "$LOG_FILE" 2>/dev/null)" == "$LOG_INODE"
]] || fail_case "PCAP-HOST-POSTCONDITIONS"
/usr/bin/cmp -s "$LOG_FILE" "$LOG_EXPECTED" ||
  fail_case "PCAP-HOST-POSTCONDITIONS"

check_sentinel_postcondition() {
  local sentinel_path="$1"
  local sentinel_device="$2"
  local sentinel_inode="$3"
  local sentinel_expected="$4"
  require_owned_regular_600 "$sentinel_path"
  [[
    "$(/usr/bin/stat -f '%d' "$sentinel_path" 2>/dev/null)" == "$sentinel_device" &&
    "$(/usr/bin/stat -f '%i' "$sentinel_path" 2>/dev/null)" == "$sentinel_inode"
  ]] || fail_case "PCAP-HOST-POSTCONDITIONS"
  /usr/bin/cmp -s "$sentinel_path" "$sentinel_expected" ||
    fail_case "PCAP-HOST-POSTCONDITIONS"
}
check_sentinel_postcondition \
  "$STATE_SENTINEL" \
  "$STATE_DEVICE" \
  "$STATE_INODE" \
  "$STATE_EXPECTED"
check_sentinel_postcondition \
  "$PREPARED_SENTINEL" \
  "$PREPARED_DEVICE" \
  "$PREPARED_INODE" \
  "$PREPARED_EXPECTED"

require_owned_regular_600 "$EXTERNAL_VICTIM"
[[
  "$(/usr/bin/stat -f '%d' "$EXTERNAL_VICTIM" 2>/dev/null)" == "$VICTIM_DEVICE" &&
  "$(/usr/bin/stat -f '%i' "$EXTERNAL_VICTIM" 2>/dev/null)" == "$VICTIM_INODE"
]] || fail_case "PCAP-HOST-POSTCONDITIONS"
/usr/bin/cmp -s "$EXTERNAL_VICTIM" "$VICTIM_EXPECTED" ||
  fail_case "PCAP-HOST-POSTCONDITIONS"
[[ -L "$ESCAPE_LINK" ]] ||
  fail_case "PCAP-HOST-POSTCONDITIONS"
/usr/bin/cmp -s "$ESCAPE_LINK" "$VICTIM_EXPECTED" ||
  fail_case "PCAP-HOST-POSTCONDITIONS"
require_owned_socket "$RUN_SOCKET"
require_owned_regular_600 "$DATABASE"
for sqlite_artifact in "$DATABASE-wal" "$DATABASE-shm"; do
  if [[ -e "$sqlite_artifact" || -L "$sqlite_artifact" ]]; then
    require_owned_regular_600 "$sqlite_artifact"
  fi
done
for absent in \
  "$RUN_FILE" \
  "$DATABASE-journal" \
  "$STATE_CREATE" \
  "$PREPARED_CREATE" \
  "$LOGS_SOCKET" \
  "$PLAYCHAIN_SOCKET"; do
  [[ ! -e "$absent" && ! -L "$absent" ]] ||
    fail_case "PCAP-HOST-POSTCONDITIONS"
done
printf '%s PASS\n' "PCAP-HOST-POSTCONDITIONS"
printf '%s PASS\n' "PCAP-AUDIT"
