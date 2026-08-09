#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL_STATE_GUARD="$ROOT_DIR/scripts/test_playcover_global_state_guard.sh"
FIXTURE_APP="$ROOT_DIR/playcover-fixtures/.build/DerivedData/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"
RUNTIME_SOURCE="$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
ENGINE_SOURCE="$ROOT_DIR/.ios-use/playcover/IOSUseFridaEngine.framework"
RELEASE_ASSET_DIR=""
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_installed_layout.sh [--release-dir <directory>] [--verify-only]

Without --release-dir, constructs checksummed assets from the current freshly
built CLI and PlayCover resources. With --release-dir, consumes the exact assets created by
scripts/release_build.sh and validates their exact five-file checksum set
before exercising an isolated temporary-prefix install. By default it also runs the installed
start/status/stop path and therefore requires the documented disposable-account
ACK and expected passwd Home. --verify-only stops after the isolated installed
layout checks; it neither launches an App nor touches account-global Mac state.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      RELEASE_ASSET_DIR="$2"
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY=1
      shift
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

if [[ "$VERIFY_ONLY" -eq 0 ]]; then
  if [[ ! -f "$GLOBAL_STATE_GUARD" || -L "$GLOBAL_STATE_GUARD" ]]; then
    echo \
      "[installed-layout] EX_CONFIG: the account-global PlayCover safety guard is unavailable" \
      >&2
    exit 78
  fi
  # shellcheck source=scripts/test_playcover_global_state_guard.sh
  source "$GLOBAL_STATE_GUARD"
  playcover_require_disposable_account_contract "installed-layout"
fi

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "[installed-layout] ERROR: release-installed Mac resources require Apple-silicon macOS" >&2
  exit 69
fi
if [[ "$VERIFY_ONLY" -eq 0 && ! -d "$FIXTURE_APP" ]]; then
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

# A live run keeps the Home short enough for Runtime sockaddr_un. Verification
# alone never creates a Runtime socket and can stay in the runner temp root.
if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iur.XXXXXX")"
else
  TEMP_ROOT="$(mktemp -d "$PLAYCOVER_ACCOUNT_HOME/.iur.XXXXXX")"
fi
ASSET_DIR="$TEMP_ROOT/a"
SOURCE_PARENT="$TEMP_ROOT/s"
SOURCE_ROOT="$SOURCE_PARENT/ios-use-release-source"
EXPECTED_PARENT="$TEMP_ROOT/e"
FAKE_BIN="$TEMP_ROOT/f"
INSTALL_HOME="$TEMP_ROOT/i"
PREFIX="$TEMP_ROOT/p"
CUSTOM_HOME="$TEMP_ROOT/h"
INSTALLED_BINARY="$PREFIX/bin/ios-use"
INSTALLED_RUNTIME="$PREFIX/share/ios-use/mac/IOSUsePlayRuntime.framework"
INSTALLED_ENGINE="$PREFIX/share/ios-use/mac/IOSUseFridaEngine.framework"
INSTALLED_ENGINE_NOTICES="$INSTALLED_ENGINE/Resources/ThirdPartyNotices.txt"
LEGACY_RULES="$PREFIX/share/ios-use/mac/default-sandbox-rules.yaml"
LOG_FILE="$TEMP_ROOT/start.log"
STATUS_FILE="$TEMP_ROOT/status.json"
SOURCE_ARCHIVE="$TEMP_ROOT/source.tar.gz"
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

mkdir -p \
  "$SOURCE_ROOT" \
  "$EXPECTED_PARENT" \
  "$FAKE_BIN" \
  "$INSTALL_HOME" \
  "$CUSTOM_HOME"

cp -R "$ROOT_DIR/ios-use-skill" "$SOURCE_ROOT/ios-use-skill"
(
  cd "$SOURCE_PARENT"
  COPYFILE_DISABLE=1 tar -czf "$SOURCE_ARCHIVE" \
    "$(basename "$SOURCE_ROOT")"
)

if [[ -z "$RELEASE_ASSET_DIR" ]]; then
  mkdir -p "$ASSET_DIR"

  install -m 755 "$ROOT_DIR/ios-use" "$ASSET_DIR/ios-use-darwin-arm64"
  # PlayCover execution never reads the XCTest driver payloads. Small,
  # distinct fixtures keep this packaging test independent of the driver build
  # job while still exercising checksum verification and both installer
  # destinations.
  printf 'release-install-test device driver\n' > "$ASSET_DIR/driver.ipa"
  printf 'release-install-test simulator driver\n' > "$ASSET_DIR/driver-sim.ipa"
  RESOURCE_STAGE="$TEMP_ROOT/resources"
  mkdir -p "$RESOURCE_STAGE"
  cp -R "$RUNTIME_SOURCE" "$RESOURCE_STAGE/IOSUsePlayRuntime.framework"
  cp -R "$ENGINE_SOURCE" "$RESOURCE_STAGE/IOSUseFridaEngine.framework"
  (
    cd "$RESOURCE_STAGE"
    COPYFILE_DISABLE=1 tar -czf \
      "$ASSET_DIR/ios-use-mac-resources.tar.gz" \
      IOSUsePlayRuntime.framework \
      IOSUseFridaEngine.framework
  )
  (
    cd "$ASSET_DIR"
    shasum -a 256 \
      ios-use-darwin-arm64 \
      driver.ipa \
      driver-sim.ipa \
      ios-use-mac-resources.tar.gz > SHA256SUMS
  )
else
  ASSET_DIR="$RELEASE_ASSET_DIR"
  required_assets=(
    ios-use-darwin-arm64
    driver.ipa
    driver-sim.ipa
    ios-use-mac-resources.tar.gz
    SHA256SUMS
  )
  for required_asset in "${required_assets[@]}"; do
    if [[ ! -s "$ASSET_DIR/$required_asset" ]]; then
      echo "[installed-layout] ERROR: release asset is missing or empty: $required_asset" >&2
      exit 1
    fi
  done
  printf '%s\n' "${required_assets[@]}" |
    LC_ALL=C sort > "$TEMP_ROOT/assets.expected"
  (
    cd "$ASSET_DIR"
    find . -mindepth 1 -maxdepth 1 -print |
      sed 's#^\./##' |
      LC_ALL=C sort
  ) > "$TEMP_ROOT/assets.actual"
  if ! cmp -s "$TEMP_ROOT/assets.expected" "$TEMP_ROOT/assets.actual"; then
    echo "[installed-layout] ERROR: release directory is not the exact five-asset set" >&2
    diff -u --label expected --label actual \
      "$TEMP_ROOT/assets.expected" "$TEMP_ROOT/assets.actual" >&2 || true
    exit 1
  fi
  awk '{ print $2 }' "$ASSET_DIR/SHA256SUMS" |
    LC_ALL=C sort > "$TEMP_ROOT/checksums.expected"
  printf '%s\n' \
    driver-sim.ipa \
    driver.ipa \
    ios-use-darwin-arm64 \
    ios-use-mac-resources.tar.gz > "$TEMP_ROOT/checksums.actual"
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

  release_binary_version="$(
    "$ASSET_DIR/ios-use-darwin-arm64" --version |
      tr -d '[:space:]'
  )"
  if [[ ! "$release_binary_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[installed-layout] ERROR: release binary has an invalid version" >&2
    exit 1
  fi
  INSTALL_VERSION_FOR_TEST="v$release_binary_version"

  tar -xzf "$ASSET_DIR/ios-use-mac-resources.tar.gz" -C "$EXPECTED_PARENT"
  EXPECTED_RUNTIME="$EXPECTED_PARENT/IOSUsePlayRuntime.framework"
  EXPECTED_ENGINE="$EXPECTED_PARENT/IOSUseFridaEngine.framework"
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
  *codeload.github.com*)
    if [[ -n "$out" ]]; then
      cp "$IOS_USE_RELEASE_TEST_SOURCE_ARCHIVE" "$out"
    else
      cat "$IOS_USE_RELEASE_TEST_SOURCE_ARCHIVE"
    fi
    exit 0
    ;;
  */ios-use-darwin-arm64) asset="ios-use-darwin-arm64" ;;
  */ios-use-mac-resources.tar.gz) asset="ios-use-mac-resources.tar.gz" ;;
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

mkdir -p "$(dirname "$LEGACY_RULES")"
printf 'legacy sandbox rules\n' > "$LEGACY_RULES"
INSTALL_OUTPUT="$(
  HOME="$INSTALL_HOME" \
    PREFIX="$PREFIX" \
    IOS_USE_GITHUB_REPO="example/ios-use" \
    IOS_USE_VERSION="$INSTALL_VERSION_FOR_TEST" \
    IOS_USE_RELEASE_TEST_ASSETS="$ASSET_DIR" \
    IOS_USE_RELEASE_TEST_SOURCE_ARCHIVE="$SOURCE_ARCHIVE" \
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
      ! -x "$INSTALLED_ENGINE/IOSUseFridaEngine" ||
      ! -s "$INSTALLED_ENGINE_NOTICES" ]]; then
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
if ! cmp -s \
     "$EXPECTED_ENGINE/Resources/ThirdPartyNotices.txt" \
     "$INSTALLED_ENGINE_NOTICES"; then
  echo "[installed-layout] ERROR: installed Frida notices differ from the release archive" >&2
  exit 1
fi
if [[ -e "$LEGACY_RULES" ]]; then
  echo "[installed-layout] ERROR: installer kept the removed sandbox YAML" >&2
  exit 1
fi

IOS_USE_HOME="$CUSTOM_HOME" \
  "$INSTALLED_BINARY" status --json > "$STATUS_FILE"
python3 - "$STATUS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
resources = payload.get("data", {}).get("macBackend", {}).get("resources", {})
if resources.get("status") != "ready":
    raise SystemExit(
        "[installed-layout] ERROR: installed Mac resource semantics are not ready: "
        + json.dumps(resources, sort_keys=True)
    )
PY

if [[ -e "$CUSTOM_HOME/mac/IOSUsePlayRuntime.framework" ]] ||
   [[ -e "$CUSTOM_HOME/mac/IOSUseFridaEngine.framework" ]] ||
   [[ -e "$PREFIX/bin/.ios-use/playcover/IOSUsePlayRuntime.framework" ]] ||
   [[ -e "$PREFIX/bin/.ios-use/playcover/IOSUseFridaEngine.framework" ]]; then
  echo "[installed-layout] ERROR: installer exposed a mutable Runtime layout" >&2
  exit 1
fi

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  if [[ -n "$RELEASE_ASSET_DIR" ]]; then
    echo "[installed-layout] exact release assets + digests + isolated install PASS"
  else
    echo "[installed-layout] real CLI/Runtime tar + checksum + isolated install PASS"
  fi
  exit 0
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
  echo "[installed-layout] exact release assets + digests + isolated install + installed execution PASS"
else
  echo "[installed-layout] real CLI/Runtime tar + checksum + isolated install + installed execution PASS"
fi
