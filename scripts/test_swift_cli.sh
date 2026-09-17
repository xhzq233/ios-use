#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SCOPE="${1:-all}"

case "$TEST_SCOPE" in
  all)
    echo "[swift-cli] Running all Swift CLI unit tests..."
    swift test --package-path "$ROOT_DIR/swift-cli"
    ;;
  general)
    echo "[swift-cli] Running general Swift CLI unit tests..."
    swift test --package-path "$ROOT_DIR/swift-cli" --skip PlayCover
    ;;
  mac)
    echo "[swift-cli] Running Mac-backend Swift CLI unit tests..."
    env NSUnbufferedIO=YES \
      swift test --package-path "$ROOT_DIR/swift-cli" --filter PlayCover
    exit 0
    ;;
  *)
    echo "[swift-cli] ERROR: expected test scope all, general, or mac" >&2
    exit 64
    ;;
esac

echo "[swift-cli] Checking driver version stamping..."
if grep -Eq 'date -u \+%Y%m%d%H%M%S|rev-parse --short=12' "$ROOT_DIR/scripts/build_driver.sh"; then
  echo "[swift-cli] ERROR: per-build driver stamping must not be reintroduced" >&2
  exit 1
fi

echo "[swift-cli] Checking driver logging API..."
if find "$ROOT_DIR/driver" \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' \) -print0 | xargs -0 grep -nE 'import os\.log|os_log\('; then
  echo "[swift-cli] ERROR: driver logs must not use os_log; use DriverLog/NSLog for openstdio collection" >&2
  exit 1
fi

echo "[swift-cli] Checking installed-style CLI invocation..."
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
  if PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$IOS_USE_TEST_HOME" ios-use stop >"$TMP_ROOT/stop.out" 2>"$TMP_ROOT/stop.err"; then
    echo "[swift-cli] ERROR: stop without driver.lock unexpectedly succeeded" >&2
    cat "$TMP_ROOT/stop.out" >&2 || true
    exit 1
  fi
  if ! grep -q 'No active driver' "$TMP_ROOT/stop.err"; then
    echo "[swift-cli] ERROR: stop without driver.lock returned unexpected error" >&2
    cat "$TMP_ROOT/stop.err" >&2 || true
    exit 1
  fi
)
