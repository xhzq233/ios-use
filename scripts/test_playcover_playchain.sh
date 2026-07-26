#!/bin/bash
set -euo pipefail

IOS_USE_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_USE_PLAYCHAIN_TEMP="$(mktemp -d /tmp/ios-use-playchain.XXXXXX)"
cleanup_playchain_test() {
  if [ -n "${IOS_USE_PLAYCHAIN_TEMP:-}" ] &&
     [ -d "$IOS_USE_PLAYCHAIN_TEMP" ] &&
     [[ "$IOS_USE_PLAYCHAIN_TEMP" == /tmp/ios-use-playchain.* ]]; then
    rm -rf "$IOS_USE_PLAYCHAIN_TEMP"
  fi
}
trap cleanup_playchain_test EXIT

IOS_USE_PLAYCHAIN_RUNTIME="$IOS_USE_REPO_ROOT/playcover-runtime"
IOS_USE_PLAYCHAIN_UPSTREAM="$IOS_USE_PLAYCHAIN_RUNTIME/PlayTools/PlayTools/MysticRunes"
IOS_USE_PLAYCHAIN_BINARY="$IOS_USE_PLAYCHAIN_TEMP/playchain-harness"
IOS_USE_PLAYCHAIN_DATABASE="$IOS_USE_PLAYCHAIN_TEMP/playchain.db"

xcrun --sdk macosx swiftc \
  -D IOS_USE_PLAYCHAIN_TESTING \
  "$IOS_USE_PLAYCHAIN_UPSTREAM/PlayedApple.swift" \
  "$IOS_USE_PLAYCHAIN_UPSTREAM/PlayedAppleDB.swift" \
  "$IOS_USE_PLAYCHAIN_UPSTREAM/PlayedAppleDBConstants.swift" \
  "$IOS_USE_PLAYCHAIN_RUNTIME/tests/PlayChainPersistenceHarness.swift" \
  -framework Security \
  -lsqlite3 \
  -o "$IOS_USE_PLAYCHAIN_BINARY"

"$IOS_USE_PLAYCHAIN_BINARY" "$IOS_USE_PLAYCHAIN_DATABASE" seed
"$IOS_USE_PLAYCHAIN_BINARY" "$IOS_USE_PLAYCHAIN_DATABASE" update
"$IOS_USE_PLAYCHAIN_BINARY" "$IOS_USE_PLAYCHAIN_DATABASE" delete

if [ ! -f "$IOS_USE_PLAYCHAIN_DATABASE" ]; then
  echo "[playchain-harness] FAIL: SQLite database was not created"
  exit 1
fi
PLAYCHAIN_MODE="$(stat -f '%Lp' "$IOS_USE_PLAYCHAIN_DATABASE")"
if [ "$PLAYCHAIN_MODE" != "600" ]; then
  echo "[playchain-harness] FAIL: database mode is $PLAYCHAIN_MODE, expected 600"
  exit 1
fi

echo "[playchain-harness] persistence and file-mode PASS"
