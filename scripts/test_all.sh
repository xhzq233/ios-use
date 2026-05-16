#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[all] Running Swift-only stack checks..."
bash "$ROOT_DIR/scripts/test_swift_stack.sh"

echo "[all] All tests passed"
