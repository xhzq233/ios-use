#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER_ARGS=()
CLI_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --debug)
      DRIVER_ARGS+=("--debug")
      CLI_ARGS+=("--debug")
      ;;
    --simulator-only)
      DRIVER_ARGS+=("--simulator-only")
      ;;
    *)
      echo "[build-all] ERROR: unknown option $arg"
      exit 1
      ;;
  esac
done

echo "[build-all] Building Swift CLI..."
bash "$ROOT_DIR/scripts/build_swift_cli.sh" "${CLI_ARGS[@]}"

echo "[build-all] Building driver..."
bash "$ROOT_DIR/scripts/build_driver.sh" "${DRIVER_ARGS[@]}"

echo "[build-all] Build complete"
