#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[all] Running Bun unit tests..."
(cd "$ROOT_DIR" && bun test)

echo "[all] Running Swift driver unit tests..."
bash "$ROOT_DIR/scripts/test_driver_unit.sh"

echo "[all] Building driver artifacts..."
bash "$ROOT_DIR/scripts/build_driver.sh"

echo "[all] Running headless Simulator command tests..."
bash "$ROOT_DIR/scripts/test_simulator_commands.sh" --skip-build

echo "[all] All tests passed"
