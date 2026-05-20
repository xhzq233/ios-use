#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_BUILDS=false
SKIP_DRIVER_SIM_BUILD=false

for arg in "$@"; do
  case "$arg" in
    --skip-builds)
      SKIP_BUILDS=true
      SKIP_DRIVER_SIM_BUILD=true
      ;;
    --skip-driver-sim-build)
      SKIP_DRIVER_SIM_BUILD=true
      ;;
    *)
      echo "[ci-test] ERROR: unknown option $arg" >&2
      exit 1
      ;;
  esac
done

echo "[ci-test] Checking script syntax..."
for script in "$ROOT_DIR"/scripts/*.sh; do
  bash -n "$script"
done
echo "[ci-test] Running install smoke tests..."
bash "$ROOT_DIR/scripts/test_install.sh"
if command -v node >/dev/null 2>&1; then
  node --check "$ROOT_DIR/scripts/benchmark_wda.js"
  node --check "$ROOT_DIR/scripts/ios_use_test_simulator.js"
  node --check "$ROOT_DIR/scripts/test_simulator_commands.mjs"
else
  echo "[ci-test] node not found; skipping Node script syntax checks"
fi

echo "[ci-test] Running Swift CLI unit tests..."
bash "$ROOT_DIR/scripts/test_swift_cli.sh"

echo "[ci-test] Running Swift driver unit tests..."
bash "$ROOT_DIR/scripts/test_driver_unit.sh"

if [ "$SKIP_BUILDS" != true ]; then
  echo "[ci-test] Building Swift CLI..."
  bash "$ROOT_DIR/scripts/build_swift_cli.sh"
else
  echo "[ci-test] Skipping Swift CLI build"
fi

if [ "$SKIP_DRIVER_SIM_BUILD" != true ]; then
  echo "[ci-test] Building Simulator driver artifact..."
  bash "$ROOT_DIR/scripts/build_driver.sh" --simulator-only
else
  echo "[ci-test] Skipping Simulator driver artifact build"
fi

echo "[ci-test] CI test gate passed"
