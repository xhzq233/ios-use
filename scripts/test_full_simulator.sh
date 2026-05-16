#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[full-sim] Running legacy Bun compatibility unit tests..."
(cd "$ROOT_DIR" && bun run test:legacy-bun)

echo "[full-sim] Running Swift-only stack checks..."
bash "$ROOT_DIR/scripts/test_swift_stack.sh"

echo "[full-sim] Running headless Simulator command matrix..."
bun "$ROOT_DIR/scripts/test_simulator_commands.ts" --skip-build

echo "[full-sim] Full Simulator regression passed"
