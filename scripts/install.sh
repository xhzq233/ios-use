#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ios-use requires macOS." >&2
  exit 1
fi

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != "-" && -e "$SCRIPT_SOURCE" ]]; then
  ROOT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")/.." 2>/dev/null && pwd || pwd)"
else
  ROOT_DIR="$(pwd)"
fi
DIST_DIR="$ROOT_DIR/dist"
OUTFILE="$DIST_DIR/ios-use"
USER_TARGET_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
PRIMARY_TARGET_DIR="$USER_TARGET_DIR"
SECONDARY_TARGET_DIR="$HOME/bin"
GITHUB_REPO="${IOS_USE_GITHUB_REPO:-xhzq233/ios-use}"
GITHUB_REF="${IOS_USE_REF:-main}"
BOOTSTRAP_DIR=""
PRINT_PATH_ONLY=0

cleanup() {
  if [[ -n "$BOOTSTRAP_DIR" && -d "$BOOTSTRAP_DIR" ]]; then
    rm -rf "$BOOTSTRAP_DIR"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-path)
      PRINT_PATH_ONLY=1
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

bootstrap_remote_repo() {
  if [[ -f "$ROOT_DIR/src/cli.ts" ]]; then
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required for remote installation." >&2
    exit 1
  fi

  BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-install.XXXXXX")"
  local archive_url="https://codeload.github.com/${GITHUB_REPO}/tar.gz/${GITHUB_REF}"
  echo "Downloading ios-use source from ${GITHUB_REPO}@${GITHUB_REF}..."
  curl -fsSL "$archive_url" | tar -xzf - -C "$BOOTSTRAP_DIR"
  ROOT_DIR="$(find "$BOOTSTRAP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$ROOT_DIR" || ! -f "$ROOT_DIR/src/cli.ts" ]]; then
    echo "Failed to bootstrap ios-use source tree." >&2
    exit 1
  fi
  DIST_DIR="$ROOT_DIR/dist"
  OUTFILE="$DIST_DIR/ios-use"
}

bootstrap_remote_repo

if ! command -v bun >/dev/null 2>&1; then
  echo "bun is required but was not found in PATH." >&2
  exit 1
fi

bun install --cwd "$ROOT_DIR"

mkdir -p "$DIST_DIR"

echo "Compiling ios-use binary..."
bun build "$ROOT_DIR/src/cli.ts" --compile --outfile "$OUTFILE"

install_binary() {
  local target_dir="$1"
  mkdir -p "$target_dir" "$HOME/.ios-use/runtime"
  install -m 755 "$OUTFILE" "$target_dir/ios-use"
  if [ -f "$ROOT_DIR/assets/driver.ipa" ]; then
    install -m 644 "$ROOT_DIR/assets/driver.ipa" "$HOME/.ios-use/driver.ipa"
  fi
  if [ -x "$ROOT_DIR/altsign-cli/altsign-cli" ]; then
    mkdir -p "$HOME/.ios-use/altsign-cli"
    install -m 755 "$ROOT_DIR/altsign-cli/altsign-cli" "$HOME/.ios-use/altsign-cli/altsign-cli"
  fi
}

resolve_target_dir() {
  if [[ -n "${PREFIX:-}" ]]; then
    printf '%s\n' "${PREFIX}/bin"
    return
  fi

  if [[ -d "$PRIMARY_TARGET_DIR" && -w "$PRIMARY_TARGET_DIR" ]]; then
    printf '%s\n' "$PRIMARY_TARGET_DIR"
    return
  fi

  case ":$PATH:" in
    *":$PRIMARY_TARGET_DIR:"*)
      printf '%s\n' "$PRIMARY_TARGET_DIR"
      return
      ;;
  esac

  if [[ -d "$SECONDARY_TARGET_DIR" && -w "$SECONDARY_TARGET_DIR" ]]; then
    printf '%s\n' "$SECONDARY_TARGET_DIR"
    return
  fi

  printf '%s\n' "$PRIMARY_TARGET_DIR"
}

TARGET_DIR="$(resolve_target_dir)"
install_binary "$TARGET_DIR"

TARGET_PATH="$TARGET_DIR/ios-use"
if [[ "$PRINT_PATH_ONLY" -eq 1 ]]; then
  printf '%s\n' "$TARGET_PATH"
  exit 0
fi

echo "Installed ios-use to $TARGET_PATH"

echo "Next steps:"
echo "  ios-use device"
echo "  ios-use config --udid <udid>"
echo "  ios-use session start --bundle-id <bundleId> --udid <udid>"
echo ""
echo "Before driving a device or Simulator you will need:"
echo "  - A full Xcode installation (provides xcrun devicectl, xctrace, simctl)"
echo "  - USB connection (for real devices)"

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *)
    echo "Add $TARGET_DIR to your PATH if needed."
    ;;
esac

echo "Verify with: $TARGET_PATH --version"
