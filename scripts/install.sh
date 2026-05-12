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
ALTSIGN_REPO="xhzq233/altsign-cli"
ALTSIGN_VERSION="v0.1.1"
DRIVER_VERSION="${IOS_USE_DRIVER_VERSION:-v1.0.0}"
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
# Workaround Bun 1.3.12 regression: built-in code signature is truncated on macOS,
# causing immediate SIGKILL (exit 137). Skip Bun's signing and manually ad-hoc sign.
BUN_NO_CODESIGN_MACHO_BINARY=1 bun build "$ROOT_DIR/src/cli.ts" --compile --outfile "$OUTFILE"
codesign --sign - --force "$OUTFILE"

install_binary() {
  local target_dir="$1"
  mkdir -p "$target_dir" "$HOME/.ios-use/runtime"
  install -m 755 "$OUTFILE" "$target_dir/ios-use"

  # driver.ipa: local assets/ > GitHub Release
  local driver_ipa="$HOME/.ios-use/driver.ipa"
  if [[ -f "$ROOT_DIR/assets/driver.ipa" ]]; then
    install -m 644 "$ROOT_DIR/assets/driver.ipa" "$driver_ipa"
  else
    echo "Downloading driver.ipa ${DRIVER_VERSION}..."
    curl -fsSL "https://github.com/${GITHUB_REPO}/releases/download/${DRIVER_VERSION}/driver.ipa" \
      -o "$driver_ipa"
  fi

  # skill: install to ~/.ios-use/skill/, symlink to ~/.agents/skills/ios-use
  local skill_src="$ROOT_DIR/ios-use-skill"
  local skill_dst="$HOME/.ios-use/skill"
  local skill_link="$HOME/.agents/skills/ios-use"
  if [[ -d "$skill_src" ]]; then
    mkdir -p "$HOME/.agents/skills"
    rm -rf "$skill_dst"
    cp -R "$skill_src" "$skill_dst"
    ln -sfn "$skill_dst" "$skill_link"
  fi

  # altsign-cli: local > GitHub Release
  local alt_bin="$HOME/.ios-use/altsign-cli/altsign-cli"
  if [[ -x "$ROOT_DIR/altsign-cli/altsign-cli" ]]; then
    mkdir -p "$HOME/.ios-use/altsign-cli"
    install -m 755 "$ROOT_DIR/altsign-cli/altsign-cli" "$alt_bin"
  elif [[ ! -x "$alt_bin" ]]; then
    echo "Downloading altsign-cli ${ALTSIGN_VERSION}..."
    mkdir -p "$HOME/.ios-use/altsign-cli"
    curl -fsSL "https://github.com/${ALTSIGN_REPO}/releases/download/${ALTSIGN_VERSION}/altsign-cli" \
      -o "$alt_bin"
    chmod +x "$alt_bin"
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

if ! xcrun --find xctrace >/dev/null 2>&1; then
  echo ""
  echo "⚠  Xcode not detected. Real device and Simulator commands require Xcode."
  echo "   Install from Mac App Store or run: xcode-select --install"
fi

echo ""
echo "Next steps:"
echo "  ios-use device"
echo "  ios-use config --udid <udid>"
echo "  ios-use dom --bundle-id <bundleId>"
echo ""
echo "No session start needed — ios-use auto-creates session on first command."
echo "USB connection required for real devices."

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *)
    echo "Add $TARGET_DIR to your PATH if needed."
    ;;
esac

echo "Verify with: $TARGET_PATH --version"
