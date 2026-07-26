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
ALTSIGN_VERSION="v0.1.3"
BOOTSTRAP_DIR=""
ROOT_DIR=""
PRINT_PATH_ONLY=0
BUILD_FROM_SOURCE=0
DIST_DIR=""
OUTFILE=""
CHECKSUM_FILE=""
RUNTIME_ARCHIVE=""

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
  --build-from-source  Compile the Swift CLI and PlayCover Runtime from the
                       selected source ref instead of downloading their
                       prebuilt GitHub Release assets.
  --print-path         Print the installed binary path after installation.

Environment:
  IOS_USE_VERSION       Release tag to install. Overridden by --version.
  IOS_USE_DRIVER_VERSION
                        Driver release tag override. Defaults to IOS_USE_VERSION.
  IOS_USE_REF           Source ref used when source files are needed.
  IOS_USE_GITHUB_REPO   GitHub repository. Defaults to xhzq233/ios-use.

Requirements:
  Apple Silicon macOS. A source build additionally requires full Xcode,
  Swift, and xcodegen; install xcodegen with `brew install xcodegen`.
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
case "$(uname -m)" in
  arm64|aarch64) ;;
  x86_64)
    echo "ios-use releases with the PlayCover Runtime require Apple Silicon; Intel macOS is unsupported." >&2
    exit 1
    ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
  command -v swift >/dev/null 2>&1 || {
    echo "Swift is required for --build-from-source." >&2
    exit 1
  }
  command -v xcodegen >/dev/null 2>&1 || {
    echo "xcodegen is required for --build-from-source; install it with: brew install xcodegen" >&2
    exit 1
  }
  xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || {
    echo "Full Xcode with the iPhoneOS SDK is required for --build-from-source." >&2
    exit 1
  }
fi
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
  CHECKSUM_FILE="$DIST_DIR/SHA256SUMS"
  RUNTIME_ARCHIVE="$DIST_DIR/ios-use-playcover-runtime.tar.gz"
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
  printf 'ios-use-darwin-arm64\n'
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
  if [[ -z "$ROOT_DIR" || ! -d "$ROOT_DIR/ios-use-skill" ]]; then
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

  download_release_checksums
  download_checked_release_asset "$(mac_cli_asset_name)" "$OUTFILE"
  download_checked_release_asset "ios-use-playcover-runtime.tar.gz" "$RUNTIME_ARCHIVE"
}

download_release_checksums() {
  echo "Downloading release checksums ${INSTALL_VERSION}..."
  curl -fsSL "$(release_asset_url "$INSTALL_VERSION" "SHA256SUMS")" -o "$CHECKSUM_FILE"
  if [[ ! -s "$CHECKSUM_FILE" ]]; then
    echo "Release SHA256SUMS is missing or empty." >&2
    exit 1
  fi
}

download_checked_release_asset() {
  local asset="$1"
  local destination="$2"
  local expected actual
  expected="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$CHECKSUM_FILE")"
  if [[ -z "$expected" || "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" != "1" ]]; then
    echo "SHA256SUMS does not contain exactly one checksum for $asset." >&2
    exit 1
  fi

  echo "Downloading ${asset} ${INSTALL_VERSION}..."
  curl -fsSL "$(release_asset_url "$INSTALL_VERSION" "$asset")" -o "$destination"
  actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $asset." >&2
    exit 1
  fi
}

install_driver_artifact() {
  local asset="$1"
  local destination="$2"
  mkdir -p "$(dirname "$destination")"

  if [[ "$BUILD_FROM_SOURCE" -eq 0 &&
        "$DRIVER_VERSION" == "$INSTALL_VERSION" ]]; then
    download_checked_release_asset "$asset" "$destination"
    return
  fi

  local driver_checksums expected actual
  driver_checksums="$DIST_DIR/SHA256SUMS-driver"
  echo "Downloading driver release checksums ${DRIVER_VERSION}..."
  curl -fsSL "$(release_asset_url "$DRIVER_VERSION" "SHA256SUMS")" -o "$driver_checksums"
  if [[ ! -s "$driver_checksums" ]]; then
    echo "Release SHA256SUMS is missing or empty at $DRIVER_VERSION." >&2
    exit 1
  fi
  expected="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$driver_checksums")"
  if [[ -z "$expected" || "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" != "1" ]]; then
    echo "SHA256SUMS does not contain exactly one checksum for $asset at $DRIVER_VERSION." >&2
    exit 1
  fi
  echo "Downloading ${asset} ${DRIVER_VERSION}..."
  curl -fsSL "$(release_asset_url "$DRIVER_VERSION" "$asset")" -o "$destination"
  actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for ${asset} ${DRIVER_VERSION}." >&2
    exit 1
  fi
}

cleanup_legacy_flow_artifacts() {
  local flows_dir="$HOME/.ios-use/flows"
  [[ -d "$flows_dir" ]] || return 0

  # Older releases installed bundled recipes here. Remove only names that
  # shipped with ios-use; leave user-authored files untouched and explain the
  # migration because the public Flow/YAML command no longer exists.
  local legacy_names=(
    proxy_clear_wifi_proxy.yaml
    proxy_configca.yaml
    proxy_set_wifi_proxy.yaml
    subflow_wait_and_find.yaml
    subflow_wait_and_match.yaml
    test_flow.yaml
    tmp_nslog_perf.yaml
  )
  local removed=()
  local name path
  for name in "${legacy_names[@]}"; do
    path="$flows_dir/$name"
    if [[ -f "$path" || -L "$path" ]]; then
      rm -f "$path"
      removed+=("$name")
    fi
  done

  if [[ "${#removed[@]}" -gt 0 ]]; then
    echo "Removed legacy bundled Flow files from $flows_dir: ${removed[*]}"
  fi

  local has_custom=0
  for path in "$flows_dir"/*; do
    if [[ -f "$path" || -L "$path" ]]; then
      has_custom=1
      break
    fi
  done
  if [[ "$has_custom" -eq 1 ]]; then
    echo "Note: custom files remain in $flows_dir, but the ios-use Flow/YAML command was removed; migrate them to shell scripts under your project."
  fi
}

runtime_destination_for_prefix() {
  local prefix="$1"
  printf '%s\n' "$prefix/share/ios-use/playcover/IOSUsePlayRuntime.framework"
}

install_playcover_runtime() {
  local prefix="$1"
  local destination source staged
  destination="$(runtime_destination_for_prefix "$prefix")"
  staged="$DIST_DIR/runtime-stage"
  rm -rf "$staged"
  mkdir -p "$staged"

  if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
    source="$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
    if [[ ! -x "$source/IOSUsePlayRuntime" ]]; then
      echo "Source build did not produce IOSUsePlayRuntime.framework." >&2
      exit 1
    fi
    cp -R "$source" "$staged/IOSUsePlayRuntime.framework"
  else
    local archived_path
    while IFS= read -r archived_path; do
      case "$archived_path" in
        IOSUsePlayRuntime.framework|IOSUsePlayRuntime.framework/*) ;;
        *)
          echo "PlayCover Runtime archive contains an unexpected path: $archived_path" >&2
          exit 1
          ;;
      esac
    done < <(tar -tzf "$RUNTIME_ARCHIVE")
    tar -xzf "$RUNTIME_ARCHIVE" -C "$staged"
  fi

  if [[ ! -x "$staged/IOSUsePlayRuntime.framework/IOSUsePlayRuntime" ]]; then
    echo "PlayCover Runtime archive does not contain IOSUsePlayRuntime.framework." >&2
    exit 1
  fi
  if [[ ! -f "$staged/IOSUsePlayRuntime.framework/Info.plist" ]] &&
     [[ ! -f "$staged/IOSUsePlayRuntime.framework/Versions/A/Resources/Info.plist" ]]; then
    echo "PlayCover Runtime archive does not contain an Info.plist." >&2
    exit 1
  fi
  if ! codesign --verify --strict "$staged/IOSUsePlayRuntime.framework" >/dev/null 2>&1; then
    echo "PlayCover Runtime signature verification failed." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  rm -rf "$destination"
  mv "$staged/IOSUsePlayRuntime.framework" "$destination"
  if ! codesign --verify --strict "$destination" >/dev/null 2>&1; then
    echo "Installed PlayCover Runtime signature verification failed." >&2
    exit 1
  fi
  echo "Installed PlayCover Runtime read-only resource to $destination"
}

install_binary() {
  local target_dir="$1"
  local install_prefix="$2"
  mkdir -p "$target_dir" "$HOME/.ios-use/runtime"
  install -m 755 "$OUTFILE" "$target_dir/ios-use"
  install_playcover_runtime "$install_prefix"

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

  cleanup_legacy_flow_artifacts

  # altsign-cli: GitHub Release
  local alt_bin="$HOME/.ios-use/altsign-cli/altsign-cli"
  local alt_ver_file="$HOME/.ios-use/altsign-cli/version"
  local installed_alt_ver=""
  [[ -f "$alt_ver_file" ]] && installed_alt_ver="$(cat "$alt_ver_file")"
  if [[ ! -x "$alt_bin" || "$installed_alt_ver" != "$ALTSIGN_VERSION" ]]; then
    echo "Downloading altsign-cli ${ALTSIGN_VERSION}..."
    mkdir -p "$HOME/.ios-use/altsign-cli"
    curl -fsSL "https://github.com/${ALTSIGN_REPO}/releases/download/${ALTSIGN_VERSION}/altsign-cli" \
      -o "$alt_bin"
    chmod +x "$alt_bin"
    printf '%s\n' "$ALTSIGN_VERSION" > "$alt_ver_file"
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

resolve_install_prefix() {
  local target_dir="$1"
  if [[ -n "${PREFIX:-}" ]]; then
    printf '%s\n' "$PREFIX"
    return
  fi
  dirname "$target_dir"
}

bootstrap_remote_repo
build_or_download_cli

TARGET_DIR="$(resolve_target_dir)"
INSTALL_PREFIX="$(resolve_install_prefix "$TARGET_DIR")"
install_binary "$TARGET_DIR" "$INSTALL_PREFIX"

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
echo "  ios-use status"
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
echo "PlayCover Runtime: $(runtime_destination_for_prefix "$INSTALL_PREFIX")"
