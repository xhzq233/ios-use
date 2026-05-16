#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[swift-cli] Running Swift CLI unit tests..."
swift test --package-path "$ROOT_DIR/swift-cli"
