#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[ci-test] Checking script syntax..."
for script in "$ROOT_DIR"/scripts/*.sh; do
  bash -n "$script"
done
node --check "$ROOT_DIR/scripts/benchmark_wda.js"
node --check "$ROOT_DIR/scripts/ios_use_test_simulator.js"
node --check "$ROOT_DIR/scripts/test_simulator_commands.mjs"

echo "[ci-test] Running Swift CLI unit tests..."
bash "$ROOT_DIR/scripts/test_swift_cli.sh"

echo "[ci-test] Running Swift driver unit tests..."
bash "$ROOT_DIR/scripts/test_driver_unit.sh"

echo "[ci-test] Building Swift CLI..."
bash "$ROOT_DIR/scripts/build_swift_cli.sh"

echo "[ci-test] Building Simulator driver artifact..."
bash "$ROOT_DIR/scripts/build_driver.sh" --simulator-only

echo "[ci-test] CI test gate passed"
