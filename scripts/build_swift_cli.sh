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

mkdir -p "$ROOT_DIR/dist"
cp "$ROOT_DIR/swift-cli/.build/$CONFIGURATION/ios-use-swift" "$ROOT_DIR/dist/ios-use-swift"
cp "$ROOT_DIR/swift-cli/.build/$CONFIGURATION/ios-use-swift" "$ROOT_DIR/dist/ios-use"
echo "[swift-cli] Built $ROOT_DIR/dist/ios-use"
echo "[swift-cli] Built $ROOT_DIR/dist/ios-use-swift"
