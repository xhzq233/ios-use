#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[swift-cli] Running Swift CLI unit tests..."
swift test --package-path "$ROOT_DIR/swift-cli"

echo "[swift-cli] Checking installed-style daemon startup..."
swift build --package-path "$ROOT_DIR/swift-cli"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-cli-invocation.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

BIN_DIR="$TMP_ROOT/bin"
WORK_DIR="$TMP_ROOT/work"
IOS_USE_TEST_HOME="$TMP_ROOT/home"
mkdir -p "$BIN_DIR" "$WORK_DIR" "$IOS_USE_TEST_HOME"
ln -sf "$ROOT_DIR/swift-cli/.build/debug/ios-use-swift" "$BIN_DIR/ios-use"

ORIGINAL_PATH="$PATH"
OUTPUT="$(
  cd "$WORK_DIR"
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$IOS_USE_TEST_HOME" ios-use config --list
)"
if [[ "$OUTPUT" != "No configured devices." ]]; then
  echo "[swift-cli] ERROR: installed-style invocation returned unexpected output:" >&2
  printf '%s\n' "$OUTPUT" >&2
  exit 1
fi

(
  cd "$WORK_DIR"
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$IOS_USE_TEST_HOME" ios-use stop >/dev/null
)
