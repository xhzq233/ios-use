#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[ci-full-sim] Checking Node Simulator command runner syntax..."
node --check "$ROOT_DIR/scripts/test_simulator_commands.mjs"

echo "[ci-full-sim] Building Swift CLI..."
bash "$ROOT_DIR/scripts/build_swift_cli.sh"

echo "[ci-full-sim] Building Simulator driver artifact..."
bash "$ROOT_DIR/scripts/build_driver.sh" --simulator-only

echo "[ci-full-sim] Running headless Simulator command matrix..."
node "$ROOT_DIR/scripts/test_simulator_commands.mjs" --skip-build "$@"

echo "[ci-full-sim] Full Simulator regression passed"
