#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[swift-cli] Running Swift CLI unit tests..."
swift test --package-path "$ROOT_DIR/swift-cli"

echo "[swift-cli] Checking driver version stamping..."
if grep -Eq 'date -u \+%Y%m%d%H%M%S|rev-parse --short=12' "$ROOT_DIR/scripts/build_driver.sh"; then
  echo "[swift-cli] ERROR: per-build driver stamping must not be reintroduced" >&2
  exit 1
fi

echo "[swift-cli] Checking driver logging API..."
if find "$ROOT_DIR/driver" \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' \) -print0 | xargs -0 grep -n 'NSLog('; then
  echo "[swift-cli] ERROR: driver logs must use DriverLog/os_log so ios-use oslog and idevicesyslog can observe them" >&2
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

echo "[swift-cli] Checking installed-style nslog streaming output..."
NSLOG_OUT="$TMP_ROOT/nslog.out"
NSLOG_ERR="$TMP_ROOT/nslog.err"
pushd "$WORK_DIR" >/dev/null
PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$IOS_USE_TEST_HOME-nslog" ios-use nslog --name ios-use-test-nslog >"$NSLOG_OUT" 2>"$NSLOG_ERR" &
NSLOG_PID=$!
popd >/dev/null
for _ in {1..50}; do
  if grep -q "NSLogger listening on port" "$NSLOG_ERR" && grep -q "Streaming logs" "$NSLOG_ERR"; then
    break
  fi
  sleep 0.1
done
if ! grep -q "NSLogger listening on port" "$NSLOG_ERR" || ! grep -q "Streaming logs" "$NSLOG_ERR"; then
  echo "[swift-cli] ERROR: nslog did not stream startup output" >&2
  echo "[swift-cli] stdout:" >&2
  cat "$NSLOG_OUT" >&2 || true
  echo "[swift-cli] stderr:" >&2
  cat "$NSLOG_ERR" >&2 || true
  kill -INT "$NSLOG_PID" 2>/dev/null || true
  wait "$NSLOG_PID" 2>/dev/null || true
  exit 1
fi
NSLOG_PORT="$(sed -n 's/.*NSLogger listening on port \([0-9][0-9]*\).*/\1/p' "$NSLOG_ERR" | head -1)"
if [[ -z "$NSLOG_PORT" ]]; then
  echo "[swift-cli] ERROR: nslog startup output did not include a parseable port" >&2
  cat "$NSLOG_ERR" >&2 || true
  kill -INT "$NSLOG_PID" 2>/dev/null || true
  wait "$NSLOG_PID" 2>/dev/null || true
  exit 1
fi
NSLOG_LISTENERS="$(lsof -nP -iTCP:"$NSLOG_PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [[ -z "$NSLOG_LISTENERS" ]] || ! grep -q "IPv4" <<<"$NSLOG_LISTENERS" || ! grep -q "IPv6" <<<"$NSLOG_LISTENERS"; then
  echo "[swift-cli] ERROR: nslog did not expose both IPv4 and IPv6 listeners on port $NSLOG_PORT" >&2
  printf '%s\n' "$NSLOG_LISTENERS" >&2
  kill -INT "$NSLOG_PID" 2>/dev/null || true
  wait "$NSLOG_PID" 2>/dev/null || true
  exit 1
fi
kill -INT "$NSLOG_PID" 2>/dev/null || true
wait "$NSLOG_PID" 2>/dev/null || true
(
  cd "$WORK_DIR"
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$IOS_USE_TEST_HOME-nslog" ios-use nslog stop >/dev/null 2>&1 || true
)

echo "[swift-cli] Checking installed-style nslog capture log separation..."
NSLOG_CAPTURE_HOME="$IOS_USE_TEST_HOME-nslog-capture"
NSLOG_START_OUT="$TMP_ROOT/nslog-start.out"
NSLOG_STOP_OUT="$TMP_ROOT/nslog-stop.out"
NSLOG_READ_OUT="$TMP_ROOT/nslog-read.out"
(
  cd "$WORK_DIR"
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$NSLOG_CAPTURE_HOME" ios-use nslog start --name ios-use-test-nslog-capture >"$NSLOG_START_OUT"
)
CAPTURE_LOG="$(awk -F'Log: ' '/^Log: / { print $2 }' "$NSLOG_START_OUT")"
if [[ -z "$CAPTURE_LOG" || ! -f "$CAPTURE_LOG" ]]; then
  echo "[swift-cli] ERROR: nslog start did not create capture log" >&2
  cat "$NSLOG_START_OUT" >&2 || true
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$NSLOG_CAPTURE_HOME" ios-use nslog stop >/dev/null 2>&1 || true
  exit 1
fi
if grep -q "NSLogger listening on port\\|Streaming logs" "$CAPTURE_LOG"; then
  echo "[swift-cli] ERROR: nslog capture log contains startup stderr output" >&2
  cat "$CAPTURE_LOG" >&2 || true
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$NSLOG_CAPTURE_HOME" ios-use nslog stop >/dev/null 2>&1 || true
  exit 1
fi
(
  cd "$WORK_DIR"
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$NSLOG_CAPTURE_HOME" ios-use nslog read >"$NSLOG_READ_OUT"
)
if grep -q "NSLogger listening on port\\|Streaming logs" "$NSLOG_READ_OUT"; then
  echo "[swift-cli] ERROR: nslog read returned startup stderr output" >&2
  cat "$NSLOG_READ_OUT" >&2 || true
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$NSLOG_CAPTURE_HOME" ios-use nslog stop >/dev/null 2>&1 || true
  exit 1
fi
(
  cd "$WORK_DIR"
  PATH="$BIN_DIR:$ORIGINAL_PATH" IOS_USE_HOME="$NSLOG_CAPTURE_HOME" ios-use nslog stop >"$NSLOG_STOP_OUT"
)
if grep -q "Interrupted by Ctrl+C\\|NSLogger interrupted" "$NSLOG_STOP_OUT"; then
  echo "[swift-cli] ERROR: nslog stop leaked interrupt noise" >&2
  cat "$NSLOG_STOP_OUT" >&2 || true
  exit 1
fi
