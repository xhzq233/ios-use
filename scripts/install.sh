#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ios-use requires macOS." >&2
  exit 1
fi

USER_TARGET_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
PRIMARY_TARGET_DIR="$USER_TARGET_DIR"
SECONDARY_TARGET_DIR="$HOME/bin"
GITHUB_REPO="${IOS_USE_GITHUB_REPO:-xhzq233/ios-use}"
CLI_VERSION=""
ALTSIGN_REPO="xhzq233/altsign-cli"
ALTSIGN_VERSION="v0.1.2"
BOOTSTRAP_DIR=""
ROOT_DIR=""
PRINT_PATH_ONLY=0
BUILD_FROM_SOURCE=0
DIST_DIR=""
OUTFILE=""

cleanup() {
  if [[ -n "$BOOTSTRAP_DIR" && -d "$BOOTSTRAP_DIR" ]]; then
    rm -rf "$BOOTSTRAP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: install.sh [--version <tag>] [--build-from-source] [--print-path]

Options:
  --version <tag>      Release tag to install (e.g. v1.2.0). Defaults to latest.
  --build-from-source  Compile the Swift CLI from the selected source ref instead
                       of downloading the prebuilt macOS CLI from the GitHub Release.
  --print-path         Print the installed binary path after installation.

Environment:
  IOS_USE_VERSION       Release tag to install. Overridden by --version.
  IOS_USE_DRIVER_VERSION
                        Driver release tag override. Defaults to IOS_USE_VERSION.
  IOS_USE_REF           Source ref used when source files are needed.
  IOS_USE_GITHUB_REPO   GitHub repository. Defaults to xhzq233/ios-use.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then
        echo "--version requires a value." >&2
        exit 1
      fi
      CLI_VERSION="$2"
      shift 2
      ;;
    --build-from-source)
      BUILD_FROM_SOURCE=1
      shift
      ;;
    --print-path)
      PRINT_PATH_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

INSTALL_VERSION="${CLI_VERSION:-${IOS_USE_VERSION:-${IOS_USE_DRIVER_VERSION:-latest}}}"
DRIVER_VERSION="${IOS_USE_DRIVER_VERSION:-$INSTALL_VERSION}"
if [[ -n "${IOS_USE_REF:-}" ]]; then
  GITHUB_REF="$IOS_USE_REF"
elif [[ "$INSTALL_VERSION" == "latest" ]]; then
  GITHUB_REF="main"
else
  GITHUB_REF="$INSTALL_VERSION"
fi

refresh_paths() {
  DIST_DIR="$ROOT_DIR/dist"
  OUTFILE="$DIST_DIR/ios-use"
}

release_asset_url() {
  local version="$1"
  local asset="$2"
  if [[ "$version" == "latest" ]]; then
    printf 'https://github.com/%s/releases/latest/download/%s\n' "$GITHUB_REPO" "$asset"
  else
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$GITHUB_REPO" "$version" "$asset"
  fi
}

mac_cli_asset_name() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    arm64|aarch64)
      printf 'ios-use-darwin-arm64\n'
      ;;
    x86_64)
      echo "Prebuilt x86_64 macOS CLI is not published. Re-run with --build-from-source." >&2
      exit 1
      ;;
    *)
      echo "Unsupported macOS architecture: $arch" >&2
      exit 1
      ;;
  esac
}

bootstrap_remote_repo() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required for remote installation." >&2
    exit 1
  fi

  BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-install.XXXXXX")"
  local archive_url="https://codeload.github.com/${GITHUB_REPO}/tar.gz/${GITHUB_REF}"
  echo "Downloading ios-use source from ${GITHUB_REPO}@${GITHUB_REF}..."
  curl -fsSL "$archive_url" | tar -xzf - -C "$BOOTSTRAP_DIR"
  ROOT_DIR="$(find "$BOOTSTRAP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$ROOT_DIR" || ! -d "$ROOT_DIR/ios-use-skill" || ! -d "$ROOT_DIR/flows" ]]; then
    echo "Failed to bootstrap ios-use source tree." >&2
    exit 1
  fi
  if [[ "$BUILD_FROM_SOURCE" -eq 1 && ! -f "$ROOT_DIR/swift-cli/Package.swift" ]]; then
    echo "Swift CLI package not found in bootstrapped source tree." >&2
    exit 1
  fi
  refresh_paths
}

build_or_download_cli() {
  mkdir -p "$DIST_DIR"

  if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
    if [[ ! -f "$ROOT_DIR/swift-cli/Package.swift" ]]; then
      echo "Swift CLI package not found at $ROOT_DIR/swift-cli" >&2
      exit 1
    fi
    echo "Compiling ios-use binary from source..."
    bash "$ROOT_DIR/scripts/build_swift_cli.sh"
    install -m 755 "$ROOT_DIR/ios-use" "$OUTFILE"
    codesign --sign - --force "$OUTFILE" >/dev/null
    return
  fi

  local cli_asset
  cli_asset="$(mac_cli_asset_name)"
  echo "Downloading ios-use ${INSTALL_VERSION} (${cli_asset})..."
  curl -fsSL "$(release_asset_url "$INSTALL_VERSION" "$cli_asset")" -o "$OUTFILE"
  chmod +x "$OUTFILE"
}

install_driver_artifact() {
  local asset="$1"
  local destination="$2"
  mkdir -p "$(dirname "$destination")"

  echo "Downloading ${asset} ${DRIVER_VERSION}..."
  curl -fsSL "$(release_asset_url "$DRIVER_VERSION" "$asset")" -o "$destination"
}

install_binary() {
  local target_dir="$1"
  mkdir -p "$target_dir" "$HOME/.ios-use/runtime"
  install -m 755 "$OUTFILE" "$target_dir/ios-use"

  install_driver_artifact "driver.ipa" "$HOME/.ios-use/driver.ipa"
  install_driver_artifact "driver-sim.ipa" "$HOME/.ios-use/driver-sim.ipa"

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

  # flows: install YAML flows to ~/.ios-use/flows/
  local flows_src="$ROOT_DIR/flows"
  local flows_dst="$HOME/.ios-use/flows"
  if [[ -d "$flows_src" ]]; then
    rm -rf "$flows_dst"
    cp -R "$flows_src" "$flows_dst"
  fi

  # altsign-cli: GitHub Release
  local alt_dir="$HOME/.ios-use/altsign-cli"
  local alt_bin="$alt_dir/altsign-cli"
  local alt_version_file="$alt_dir/version"
  local installed_alt_version=""
  if [[ -f "$alt_version_file" ]]; then
    installed_alt_version="$(tr -d '[:space:]' < "$alt_version_file")"
  fi
  if [[ ! -x "$alt_bin" || "$installed_alt_version" != "$ALTSIGN_VERSION" ]]; then
    echo "Downloading altsign-cli ${ALTSIGN_VERSION}..."
    mkdir -p "$alt_dir"
    local alt_tmp="${alt_bin}.tmp.$$"
    rm -f "$alt_tmp"
    curl -fsSL "https://github.com/${ALTSIGN_REPO}/releases/download/${ALTSIGN_VERSION}/altsign-cli" \
      -o "$alt_tmp"
    chmod +x "$alt_tmp"
    mv "$alt_tmp" "$alt_bin"
    printf '%s\n' "$ALTSIGN_VERSION" > "$alt_version_file"
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

bootstrap_remote_repo
build_or_download_cli

TARGET_DIR="$(resolve_target_dir)"
install_binary "$TARGET_DIR"

TARGET_PATH="$TARGET_DIR/ios-use"
if [[ "$PRINT_PATH_ONLY" -eq 1 ]]; then
  printf '%s\n' "$TARGET_PATH"
  exit 0
fi

echo "Installed ios-use to $TARGET_PATH"

if ! xcrun --find simctl >/dev/null 2>&1; then
  echo ""
  echo "Note: Xcode not detected. Real-device release usage works without Xcode."
  echo "   Simulator support and local driver builds require full Xcode."
fi

echo ""
echo "Next steps:"
echo "  ios-use devices"
echo "  ios-use config --udid <udid>"
echo "  ios-use start <udid>"
echo "  ios-use activateApp <bundleId>"
echo "  ios-use dom"
echo ""
echo "Run ios-use stop before switching to another device."
echo "USB connection required for real devices."

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *)
    echo "Add $TARGET_DIR to your PATH if needed."
    ;;
esac

echo "Verify with: $TARGET_PATH --version"
