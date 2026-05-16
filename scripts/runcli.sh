#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[runcli] Building Swift CLI debug binary..."
swift build --package-path "$ROOT_DIR/swift-cli" -c debug

BIN_DIR="$(swift build --package-path "$ROOT_DIR/swift-cli" -c debug --show-bin-path)"
exec "$BIN_DIR/ios-use-swift" "$@"
