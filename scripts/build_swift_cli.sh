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

cp "$ROOT_DIR/swift-cli/.build/$CONFIGURATION/ios-use-swift" "$ROOT_DIR/ios-use"
chmod +x "$ROOT_DIR/ios-use"

if [ "$CONFIGURATION" = "release" ]; then
  echo "[swift-cli] Stripping release binary..."
  strip "$ROOT_DIR/ios-use"
fi

echo "[swift-cli] Built $ROOT_DIR/ios-use"
