#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL_STATE_GUARD="$ROOT_DIR/scripts/test_playcover_global_state_guard.sh"
FIXTURE_APP="$ROOT_DIR/playcover-fixtures/.build/DerivedData/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"
RUNTIME_SOURCE="$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
ENGINE_SOURCE="$ROOT_DIR/.ios-use/playcover/IOSUseFridaEngine.framework"
RELEASE_ASSET_DIR=""

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_installed_layout.sh [--release-dir <directory>]

Without --release-dir, constructs checksummed assets from the current freshly
built CLI and PlayCover resources. With --release-dir, consumes the exact assets created by
scripts/release_build.sh and validates their checksum/build/source manifests
before exercising install and the installed start/status/stop path. Both modes
require the documented disposable-account ACK and expected passwd Home.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      RELEASE_ASSET_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if [[ ! -f "$GLOBAL_STATE_GUARD" || -L "$GLOBAL_STATE_GUARD" ]]; then
  echo \
    "[installed-layout] EX_CONFIG: the account-global PlayCover safety guard is unavailable" \
    >&2
  exit 78
fi
# shellcheck source=scripts/test_playcover_global_state_guard.sh
source "$GLOBAL_STATE_GUARD"
playcover_require_disposable_account_contract "installed-layout"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "[installed-layout] ERROR: release-installed PlayCover execution requires Apple-silicon macOS" >&2
  exit 69
fi
if [[ ! -d "$FIXTURE_APP" ]]; then
  echo "[installed-layout] ERROR: PlayCover fixture is missing; the owning gate must rebuild it first" >&2
  exit 1
fi
if [[ -z "$RELEASE_ASSET_DIR" ]]; then
  if [[ ! -x "$ROOT_DIR/ios-use" ]]; then
    echo "[installed-layout] ERROR: current workspace CLI is missing; the owning gate must rebuild it first" >&2
    exit 1
  fi
  if [[ ! -x "$RUNTIME_SOURCE/IOSUsePlayRuntime" ]]; then
    echo "[installed-layout] ERROR: current signed Runtime is missing; the owning gate must rebuild it first" >&2
    exit 1
  fi
  if [[ ! -x "$ENGINE_SOURCE/IOSUseFridaEngine" ]]; then
    echo "[installed-layout] ERROR: current pinned Frida Engine is missing; build it before this release gate" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --strict "$RUNTIME_SOURCE"
  /usr/bin/codesign --verify --strict "$ENGINE_SOURCE"
else
  if [[ ! -d "$RELEASE_ASSET_DIR" ]]; then
    echo "[installed-layout] ERROR: release asset directory does not exist: $RELEASE_ASSET_DIR" >&2
    exit 1
  fi
  RELEASE_ASSET_DIR="$(cd "$RELEASE_ASSET_DIR" && pwd -P)"
fi

# Keep the canonical test home short enough for the Runtime's sockaddr_un
# safety limit and avoid /tmp -> /private/tmp aliasing.
CANONICAL_HOME="$PLAYCOVER_ACCOUNT_HOME"
TEMP_ROOT="$(mktemp -d "$CANONICAL_HOME/.iur.XXXXXX")"
ASSET_DIR="$TEMP_ROOT/a"
SOURCE_PARENT="$TEMP_ROOT/s"
SOURCE_ROOT="$SOURCE_PARENT/ios-use-release-source"
EXPECTED_PARENT="$TEMP_ROOT/e"
FAKE_BIN="$TEMP_ROOT/f"
INSTALL_HOME="$TEMP_ROOT/i"
PREFIX="$TEMP_ROOT/p"
CUSTOM_HOME="$TEMP_ROOT/h"
INSTALLED_BINARY="$PREFIX/bin/ios-use"
INSTALLED_RUNTIME="$PREFIX/share/ios-use/playcover/IOSUsePlayRuntime.framework"
INSTALLED_ENGINE="$PREFIX/share/ios-use/playcover/IOSUseFridaEngine.framework"
LOG_FILE="$TEMP_ROOT/start.log"
STATUS_FILE="$TEMP_ROOT/status.json"
SOURCE_ASSET="source.tar.gz"
INSTALL_VERSION_FOR_TEST="v0.0.0-test"
EXPECTED_RUNTIME="$RUNTIME_SOURCE"
EXPECTED_ENGINE="$ENGINE_SOURCE"
START_ATTEMPTED=0
SESSION_STOPPED=0

cleanup() {
  if [[ "$START_ATTEMPTED" -eq 1 &&
        "$SESSION_STOPPED" -eq 0 &&
        -x "$INSTALLED_BINARY" ]]; then
    if ! (
      cd "$TEMP_ROOT"
      IOS_USE_HOME="$CUSTOM_HOME" \
        "$INSTALLED_BINARY" stop \
          >"$TEMP_ROOT/cleanup-stop.log" 2>&1
    ); then
      echo \
        "[installed-layout] preserving failed launch evidence: $TEMP_ROOT" \
        >&2
      return
    fi
  fi
  if [[ -d "$TEMP_ROOT" ]]; then
    chmod -R u+w "$TEMP_ROOT"
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

runtime_content_manifest() {
  local framework="$1"
  local output="$2"
  local relative
  : > "$output"
  while IFS= read -r relative; do
    if [[ -L "$framework/$relative" ]]; then
      printf 'symlink:%s  %s\n' \
        "$(readlink "$framework/$relative")" "$relative" >> "$output"
    elif [[ -f "$framework/$relative" ]]; then
      printf '%s  %s\n' \
        "$(shasum -a 256 "$framework/$relative" | awk '{print $1}')" \
        "$relative" >> "$output"
    fi
  done < <(
    cd "$framework"
    find . \( -type f -o -type l \) -print |
      sed 's#^\./##' |
      LC_ALL=C sort
  )
}

runtime_source_digest() {
  local source_tree="$1"
  local manifest="$2"
  local relative
  : > "$manifest"
  while IFS= read -r relative; do
    if [[ ! -f "$source_tree/$relative" ]]; then
      echo "[installed-layout] ERROR: corresponding source Runtime input is missing: $relative" >&2
      exit 1
    fi
    printf '%s  %s\n' \
      "$(shasum -a 256 "$source_tree/$relative" | awk '{print $1}')" \
      "$relative" >> "$manifest"
  done < <(
    cd "$source_tree"
    {
      find playcover-runtime -type f -print
      find swift-cli/Sources/IOSUsePlayDevice -type f -print
      printf '%s\n' scripts/build_playcover_runtime.sh
    } |
      LC_ALL=C sort
  )
  shasum -a 256 "$manifest" | awk '{print $1}'
}

mkdir -p \
  "$SOURCE_ROOT" \
  "$EXPECTED_PARENT" \
  "$FAKE_BIN" \
  "$INSTALL_HOME" \
  "$CUSTOM_HOME"

if [[ -z "$RELEASE_ASSET_DIR" ]]; then
  mkdir -p "$ASSET_DIR"
  cp -R "$ROOT_DIR/ios-use-skill" "$SOURCE_ROOT/ios-use-skill"
  (
    cd "$SOURCE_PARENT"
    COPYFILE_DISABLE=1 tar -czf "$ASSET_DIR/$SOURCE_ASSET" \
      "$(basename "$SOURCE_ROOT")"
  )

  install -m 755 "$ROOT_DIR/ios-use" "$ASSET_DIR/ios-use-darwin-arm64"
  # PlayCover execution never reads the XCTest driver payloads. Small,
  # distinct fixtures keep this packaging test independent of the driver build
  # job while still exercising checksum verification and both installer
  # destinations.
  printf 'release-install-test device driver\n' > "$ASSET_DIR/driver.ipa"
  printf 'release-install-test simulator driver\n' > "$ASSET_DIR/driver-sim.ipa"
  (
    cd "$(dirname "$RUNTIME_SOURCE")"
    COPYFILE_DISABLE=1 tar -czf \
      "$ASSET_DIR/ios-use-playcover-resources.tar.gz" \
      "$(basename "$RUNTIME_SOURCE")" \
      "$(basename "$ENGINE_SOURCE")"
  )
  (
    cd "$ASSET_DIR"
    shasum -a 256 \
      ios-use-darwin-arm64 \
      driver.ipa \
      driver-sim.ipa \
      ios-use-playcover-resources.tar.gz > SHA256SUMS
  )
else
  ASSET_DIR="$RELEASE_ASSET_DIR"
  required_assets=(
    ios-use-darwin-arm64
    driver.ipa
    driver-sim.ipa
    ios-use-playcover-resources.tar.gz
    LICENSE
    PLAYCOVER-LICENSE-GPL-3.0
    PLAYTOOLS-LICENSE-AGPL-3.0
    INJECT-LICENSE-GPL-3.0
    YAMS-LICENSE-MIT
    THIRD-PARTY-LICENSES.md
    SHA256SUMS
  )
  for required_asset in "${required_assets[@]}"; do
    if [[ ! -s "$ASSET_DIR/$required_asset" ]]; then
      echo "[installed-layout] ERROR: release asset is missing or empty: $required_asset" >&2
      exit 1
    fi
  done
  awk '{ print $2 }' "$ASSET_DIR/SHA256SUMS" |
    LC_ALL=C sort > "$TEMP_ROOT/checksums.expected"
  (
    cd "$ASSET_DIR"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print |
      sed 's#^\./##' |
      LC_ALL=C sort
  ) > "$TEMP_ROOT/checksums.actual"
  if ! cmp -s "$TEMP_ROOT/checksums.expected" "$TEMP_ROOT/checksums.actual"; then
    echo "[installed-layout] ERROR: SHA256SUMS does not cover the exact release asset file set" >&2
    diff -u --label "checksummed assets" --label "release assets" \
      "$TEMP_ROOT/checksums.expected" "$TEMP_ROOT/checksums.actual" >&2 || true
    exit 1
  fi
  (
    cd "$ASSET_DIR"
    shasum -a 256 -c SHA256SUMS
  ) >/dev/null

  shopt -s nullglob
  source_assets=("$ASSET_DIR"/ios-use-v*-corresponding-source.tar.gz)
  build_manifests=("$ASSET_DIR"/PLAYCOVER-BUILD-MANIFEST-v*.txt)
  provenance_assets=("$ASSET_DIR"/PLAYCOVER-PROVENANCE-v*.md)
  changelog_assets=("$ASSET_DIR"/CHANGELOG-v*.md)
  shopt -u nullglob
  if [[ "${#source_assets[@]}" -ne 1 ||
        "${#build_manifests[@]}" -ne 1 ||
        "${#provenance_assets[@]}" -ne 1 ||
        "${#changelog_assets[@]}" -ne 1 ]]; then
    echo "[installed-layout] ERROR: release requires exactly one versioned source, build-manifest, provenance, and changelog asset" >&2
    exit 1
  fi
  SOURCE_ASSET="$(basename "${source_assets[0]}")"
  INSTALL_VERSION_FOR_TEST="${SOURCE_ASSET#ios-use-}"
  INSTALL_VERSION_FOR_TEST="${INSTALL_VERSION_FOR_TEST%-corresponding-source.tar.gz}"
  build_manifest_basename="$(basename "${build_manifests[0]}")"
  provenance_basename="$(basename "${provenance_assets[0]}")"
  changelog_basename="$(basename "${changelog_assets[0]}")"
  release_binary_version="$(
    "$ASSET_DIR/ios-use-darwin-arm64" --version |
      tr -d '[:space:]'
  )"
  if [[ "$build_manifest_basename" != "PLAYCOVER-BUILD-MANIFEST-$INSTALL_VERSION_FOR_TEST.txt" ||
        "$provenance_basename" != "PLAYCOVER-PROVENANCE-$INSTALL_VERSION_FOR_TEST.md" ||
        "$changelog_basename" != "CHANGELOG-$INSTALL_VERSION_FOR_TEST.md" ||
        "$release_binary_version" != "${INSTALL_VERSION_FOR_TEST#v}" ]]; then
    echo "[installed-layout] ERROR: release binary and versioned asset names disagree" >&2
    exit 1
  fi

  tar -xzf "$ASSET_DIR/ios-use-playcover-resources.tar.gz" -C "$EXPECTED_PARENT"
  EXPECTED_RUNTIME="$EXPECTED_PARENT/IOSUsePlayRuntime.framework"
  EXPECTED_ENGINE="$EXPECTED_PARENT/IOSUseFridaEngine.framework"
  tar -xzf "$ASSET_DIR/$SOURCE_ASSET" -C "$SOURCE_PARENT"
  source_roots=("$SOURCE_PARENT"/ios-use-v*)
  if [[ "${#source_roots[@]}" -ne 1 ||
        ! -d "${source_roots[0]}/ios-use-skill" ||
        ! -d "${source_roots[0]}/ThirdParty/Yams/upstream-source" ||
        ! -s "${source_roots[0]}/ThirdParty/Yams/PROVENANCE.md" ||
        ! -s "${source_roots[0]}/CORRESPONDING-SOURCE-MANIFEST.txt" ]]; then
    echo "[installed-layout] ERROR: corresponding source lacks its versioned root, skill, Yams source, or source manifest" >&2
    exit 1
  fi
  if ! cmp -s \
       "$ASSET_DIR/YAMS-LICENSE-MIT" \
       "${source_roots[0]}/ThirdParty/Yams/LICENSE" ||
     ! cmp -s \
       "$ASSET_DIR/YAMS-LICENSE-MIT" \
       "${source_roots[0]}/ThirdParty/Yams/upstream-source/LICENSE" ||
     ! cmp -s \
       "$ASSET_DIR/THIRD-PARTY-LICENSES.md" \
       "${source_roots[0]}/ThirdParty/LICENSES.md"; then
    echo "[installed-layout] ERROR: release and corresponding-source license materials differ" >&2
    exit 1
  fi

  BUILD_MANIFEST="${build_manifests[0]}"
  if ! grep -Fq "\`$SOURCE_ASSET\`" "${provenance_assets[0]}" ||
     ! grep -Fq "\`$(basename "$BUILD_MANIFEST")\`" "${provenance_assets[0]}"; then
    echo "[installed-layout] ERROR: release provenance does not name its exact source and build manifest assets" >&2
    exit 1
  fi
  expected_runtime_archive_sha="$(
    awk -F': ' '$1 == "PlayCover resources archive SHA-256" { print $2 }' \
      "$BUILD_MANIFEST"
  )"
  expected_source_archive_sha="$(
    awk -F': ' '$1 == "Corresponding-source archive SHA-256" { print $2 }' \
      "$BUILD_MANIFEST"
  )"
  expected_runtime_source_sha="$(
    awk -F': ' '$1 == "PlayCover Runtime input manifest SHA-256" { print $2 }' \
      "$BUILD_MANIFEST"
  )"
  archived_runtime_source_sha="$(
    runtime_source_digest \
      "${source_roots[0]}" \
      "$TEMP_ROOT/runtime-source.archived"
  )"
  if [[ "$expected_runtime_archive_sha" != "$(
          shasum -a 256 "$ASSET_DIR/ios-use-playcover-resources.tar.gz" |
            awk '{print $1}'
        )" ||
        "$expected_source_archive_sha" != "$(
          shasum -a 256 "$ASSET_DIR/$SOURCE_ASSET" |
            awk '{print $1}'
        )" ||
        "$expected_runtime_source_sha" != "$(
          awk -F': ' '$1 == "PlayCover Runtime input manifest SHA-256" { print $2 }' \
            "${source_roots[0]}/CORRESPONDING-SOURCE-MANIFEST.txt"
        )" ||
        "$expected_runtime_source_sha" != "$archived_runtime_source_sha" ]]; then
    echo "[installed-layout] ERROR: release build/source/archive digest evidence is inconsistent" >&2
    exit 1
  fi
fi

cat > "$FAKE_BIN/curl" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
url=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

asset=""
case "$url" in
  *codeload.github.com*) asset="$IOS_USE_RELEASE_TEST_SOURCE_ASSET" ;;
  */ios-use-darwin-arm64) asset="ios-use-darwin-arm64" ;;
  */ios-use-playcover-resources.tar.gz) asset="ios-use-playcover-resources.tar.gz" ;;
  */driver.ipa) asset="driver.ipa" ;;
  */driver-sim.ipa) asset="driver-sim.ipa" ;;
  */SHA256SUMS) asset="SHA256SUMS" ;;
  */altsign-cli)
    if [[ -n "$out" ]]; then
      printf '#!/bin/sh\nexit 0\n' > "$out"
      chmod +x "$out"
    else
      printf '#!/bin/sh\nexit 0\n'
    fi
    exit 0
    ;;
  *)
    echo "[installed-layout] unexpected download URL: $url" >&2
    exit 1
    ;;
esac

if [[ -n "$out" ]]; then
  cp "$IOS_USE_RELEASE_TEST_ASSETS/$asset" "$out"
else
  cat "$IOS_USE_RELEASE_TEST_ASSETS/$asset"
fi
SCRIPT
chmod +x "$FAKE_BIN/curl"

INSTALL_OUTPUT="$(
  HOME="$INSTALL_HOME" \
    PREFIX="$PREFIX" \
    IOS_USE_GITHUB_REPO="example/ios-use" \
    IOS_USE_VERSION="$INSTALL_VERSION_FOR_TEST" \
    IOS_USE_RELEASE_TEST_ASSETS="$ASSET_DIR" \
    IOS_USE_RELEASE_TEST_SOURCE_ASSET="$SOURCE_ASSET" \
    PATH="$FAKE_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$ROOT_DIR/scripts/install.sh" --print-path
)"
if [[ "$(printf '%s\n' "$INSTALL_OUTPUT" | tail -n 1)" != "$INSTALLED_BINARY" ]]; then
  printf '%s\n' "$INSTALL_OUTPUT" >&2
  echo "[installed-layout] ERROR: release installer returned an unexpected binary path" >&2
  exit 1
fi
if [[ ! -x "$INSTALLED_BINARY" ||
      ! -x "$INSTALLED_RUNTIME/IOSUsePlayRuntime" ||
      ! -x "$INSTALLED_ENGINE/IOSUseFridaEngine" ]]; then
  echo "[installed-layout] ERROR: release assets were not installed into the prefix layout" >&2
  exit 1
fi
if ! cmp -s "$ASSET_DIR/ios-use-darwin-arm64" "$INSTALLED_BINARY"; then
  echo "[installed-layout] ERROR: installed CLI differs from the checksummed release asset" >&2
  exit 1
fi
runtime_content_manifest "$EXPECTED_RUNTIME" "$TEMP_ROOT/runtime.expected"
runtime_content_manifest "$INSTALLED_RUNTIME" "$TEMP_ROOT/runtime.installed.before"
if ! cmp -s "$TEMP_ROOT/runtime.expected" "$TEMP_ROOT/runtime.installed.before"; then
  echo "[installed-layout] ERROR: installed Runtime differs from the release archive" >&2
  diff -u --label "release Runtime" --label "installed Runtime" \
    "$TEMP_ROOT/runtime.expected" "$TEMP_ROOT/runtime.installed.before" >&2 || true
  exit 1
fi
/usr/bin/codesign --verify --strict "$INSTALLED_RUNTIME"
runtime_content_manifest "$EXPECTED_ENGINE" "$TEMP_ROOT/engine.expected"
runtime_content_manifest "$INSTALLED_ENGINE" "$TEMP_ROOT/engine.installed.before"
if ! cmp -s "$TEMP_ROOT/engine.expected" "$TEMP_ROOT/engine.installed.before"; then
  echo "[installed-layout] ERROR: installed Engine differs from the release archive" >&2
  exit 1
fi
/usr/bin/codesign --verify --strict "$INSTALLED_ENGINE"

if [[ -e "$CUSTOM_HOME/mac/IOSUsePlayRuntime.framework" ]] ||
   [[ -e "$CUSTOM_HOME/mac/IOSUseFridaEngine.framework" ]] ||
   [[ -e "$PREFIX/bin/.ios-use/playcover/IOSUsePlayRuntime.framework" ]] ||
   [[ -e "$PREFIX/bin/.ios-use/playcover/IOSUseFridaEngine.framework" ]]; then
  echo "[installed-layout] ERROR: installer exposed a mutable Runtime layout" >&2
  exit 1
fi

START_ATTEMPTED=1
set +e
(
  cd "$TEMP_ROOT"
  IOS_USE_HOME="$CUSTOM_HOME" \
    "$INSTALLED_BINARY" start --mac --app "$FIXTURE_APP"
) >"$LOG_FILE" 2>&1
START_STATUS=$?
set -e
if grep -q 'no default IOSUsePlayRuntime.framework found' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "[installed-layout] ERROR: installed CLI did not discover the release-installed Runtime" >&2
  exit 1
fi
if [[ "$START_STATUS" -ne 0 ]]; then
  cat "$LOG_FILE" >&2
  echo "[installed-layout] ERROR: release-installed CLI failed after Runtime discovery" >&2
  exit "$START_STATUS"
fi

(
  cd "$TEMP_ROOT"
  IOS_USE_HOME="$CUSTOM_HOME" \
    "$INSTALLED_BINARY" status --json >"$STATUS_FILE"
  IOS_USE_HOME="$CUSTOM_HOME" "$INSTALLED_BINARY" stop
)
SESSION_STOPPED=1
RUNTIME_SOCKET="$(
  jq -er '.data.driver.macRuntimeSocketPath' "$STATUS_FILE"
)"
if [[ -e "$RUNTIME_SOCKET" || -L "$RUNTIME_SOCKET" ]]; then
  echo "[installed-layout] ERROR: normal stop left its Runtime-owned socket path" >&2
  exit 1
fi
if [[ -e "$CUSTOM_HOME/mac/IOSUsePlayRuntime.framework" ]]; then
  echo "[installed-layout] ERROR: installed execution copied executable Runtime content into IOS_USE_HOME" >&2
  exit 1
fi
runtime_content_manifest "$INSTALLED_RUNTIME" "$TEMP_ROOT/runtime.installed.after"
if ! cmp -s "$TEMP_ROOT/runtime.installed.before" "$TEMP_ROOT/runtime.installed.after"; then
  echo "[installed-layout] ERROR: installed execution mutated the read-only Runtime" >&2
  diff -u --label "installed Runtime before execution" \
    --label "installed Runtime after execution" \
    "$TEMP_ROOT/runtime.installed.before" "$TEMP_ROOT/runtime.installed.after" >&2 || true
  exit 1
fi
runtime_content_manifest "$INSTALLED_ENGINE" "$TEMP_ROOT/engine.installed.after"
if ! cmp -s "$TEMP_ROOT/engine.installed.before" "$TEMP_ROOT/engine.installed.after"; then
  echo "[installed-layout] ERROR: normal start mutated the installed Engine resource" >&2
  exit 1
fi

if [[ -n "$RELEASE_ASSET_DIR" ]]; then
  echo "[installed-layout] exact release assets + digests + read-only install + installed execution PASS"
else
  echo "[installed-layout] real CLI/Runtime tar + checksum + read-only install + installed execution PASS"
fi
