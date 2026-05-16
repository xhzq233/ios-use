#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[full-sim] Running Swift-only stack checks..."
bash "$ROOT_DIR/scripts/test_swift_stack.sh"

echo "[full-sim] Checking Node Simulator command runner syntax..."
node --check "$ROOT_DIR/scripts/test_simulator_commands.mjs"

echo "[full-sim] Running headless Simulator command matrix..."
node "$ROOT_DIR/scripts/test_simulator_commands.mjs" --skip-build

echo "[full-sim] Full Simulator regression passed"
