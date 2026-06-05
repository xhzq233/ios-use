#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="release"

for arg in "$@"; do
  case "$arg" in
    --debug)
      CONFIGURATION="debug"
      ;;
    *)
      echo "[swift-cli] ERROR: unknown option $arg"
      exit 1
      ;;
  esac
done

echo "[swift-cli] Building ios-use ($CONFIGURATION)..."
swift build --package-path "$ROOT_DIR/swift-cli" -c "$CONFIGURATION"

TMP_BIN="$(mktemp "$ROOT_DIR/.ios-use.tmp.XXXXXX")"
cleanup() {
  rm -f "$TMP_BIN"
}
trap cleanup EXIT

cp "$ROOT_DIR/swift-cli/.build/$CONFIGURATION/ios-use-swift" "$TMP_BIN"
chmod +x "$TMP_BIN"

if [ "$CONFIGURATION" = "release" ]; then
  echo "[swift-cli] Stripping release binary..."
  strip "$TMP_BIN"
fi

mv "$TMP_BIN" "$ROOT_DIR/ios-use"
trap - EXIT

echo "[swift-cli] Built $ROOT_DIR/ios-use"
