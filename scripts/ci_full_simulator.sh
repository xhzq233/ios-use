#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

driver_ipa=""
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  if [[ "$arg" == "--driver-ipa" ]]; then
    next=$((i + 1))
    if (( next <= $# )); then
      driver_ipa="${!next}"
    fi
  elif [[ "$arg" == --driver-ipa=* ]]; then
    driver_ipa="${arg#--driver-ipa=}"
  fi
done

if [[ -z "$driver_ipa" ]]; then
  echo "[ci-full-sim] error: --driver-ipa <path> is required; build or select the Simulator driver IPA before running full Simulator tests" >&2
  exit 2
fi

echo "[ci-full-sim] Checking Node Simulator command runner syntax..."
node --check "$ROOT_DIR/scripts/test_simulator_commands.mjs"

echo "[ci-full-sim] Building Swift CLI..."
bash "$ROOT_DIR/scripts/build_swift_cli.sh"

echo "[ci-full-sim] Running headless Simulator command matrix..."
node "$ROOT_DIR/scripts/test_simulator_commands.mjs" --skip-build "$@"

echo "[ci-full-sim] Full Simulator regression passed"
