#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[swift-stack] Running Swift CLI unit tests..."
bash "$ROOT_DIR/scripts/test_swift_cli.sh"

echo "[swift-stack] Running Swift driver unit tests..."
bash "$ROOT_DIR/scripts/test_driver_unit.sh"

echo "[swift-stack] Building Swift CLI..."
bash "$ROOT_DIR/scripts/build_swift_cli.sh"

echo "[swift-stack] Building Simulator driver artifact..."
bash "$ROOT_DIR/scripts/build_driver.sh" --simulator-only

echo "[swift-stack] Swift-only stack checks passed"
