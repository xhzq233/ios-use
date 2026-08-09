#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
RELEASE_STARTED_AT="$(date +%s)"
RELEASE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-release-build.XXXXXX")"
UPSTREAM_CACHE="${IOS_USE_PLAYCOVER_UPSTREAM_CACHE:-${TMPDIR:-/tmp}/ios-use-playcover-upstream-audit}"

cleanup() {
  if [[ -d "$RELEASE_TEMP" ]]; then
    chmod -R u+w "$RELEASE_TEMP"
  fi
  rm -rf "$RELEASE_TEMP"
}
trap cleanup EXIT

require_clean_source_tree() {
  local phase="$1"
  local dirty
  if ! git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "[release-build] ERROR: release assets must be produced from a Git checkout" >&2
    exit 1
  fi
  dirty="$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)"
  if [[ -n "$dirty" ]]; then
    echo "[release-build] ERROR: source tree is dirty $phase; refusing release assets." >&2
    printf '%s\n' "$dirty" >&2
    exit 1
  fi
}

runtime_source_manifest() {
  local source_root="$1"
  local output="$2"
  local relative
  : > "$output"
  while IFS= read -r relative; do
    if [[ ! -f "$source_root/$relative" ]]; then
      echo "[release-build] ERROR: Runtime build input is missing from source: $relative" >&2
      exit 1
    fi
    printf '%s  %s\n' \
      "$(shasum -a 256 "$source_root/$relative" | awk '{print $1}')" \
      "$relative" >> "$output"
  done < <(
    git -C "$ROOT_DIR" ls-files -- \
      playcover-runtime \
      swift-cli/Sources/IOSUsePlayDevice \
      scripts/build_playcover_runtime.sh |
      LC_ALL=C sort
  )
  if [[ ! -s "$output" ]]; then
    echo "[release-build] ERROR: Runtime source manifest is empty" >&2
    exit 1
  fi
}

require_clean_source_tree "before the build"

echo "[release-build] Auditing pinned PlayCover upstreams..."
bash "$ROOT_DIR/scripts/audit_playcover_upstreams.sh" --cache-dir "$UPSTREAM_CACHE"

RUNTIME_INPUTS_BEFORE="$RELEASE_TEMP/runtime-inputs.before"
RUNTIME_INPUTS_AFTER="$RELEASE_TEMP/runtime-inputs.after"
runtime_source_manifest "$ROOT_DIR" "$RUNTIME_INPUTS_BEFORE"

echo "[release-build] Building Mac Runtime from a fresh derived-data directory..."
bash "$ROOT_DIR/scripts/build_playcover_runtime.sh" --replace

echo "[release-build] Building Swift CLI..."
STEP_STARTED_AT="$(date +%s)"
bash "$ROOT_DIR/scripts/build_swift_cli.sh"
STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[release-build] Swift CLI completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"

ACTUAL_VERSION="$("$ROOT_DIR/ios-use" --version | tr -d '[:space:]')"
if [ -n "${IOS_USE_RELEASE_VERSION:-}" ]; then
  STEP_STARTED_AT="$(date +%s)"
  EXPECTED_VERSION="${IOS_USE_RELEASE_VERSION#v}"
  if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "[release-build] ERROR: binary version $ACTUAL_VERSION does not match release tag $IOS_USE_RELEASE_VERSION" >&2
    exit 1
  fi
  echo "[release-build] Version check passed: $ACTUAL_VERSION"
  STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
  printf '[release-build] Version check completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
fi

echo "[release-build] Building driver IPAs..."
STEP_STARTED_AT="$(date +%s)"
bash "$ROOT_DIR/scripts/build_driver.sh" --release
STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[release-build] Driver IPAs completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"

echo "[release-build] Preparing release assets..."
STEP_STARTED_AT="$(date +%s)"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
cp "$ROOT_DIR/ios-use" "$RELEASE_DIR/ios-use-darwin-arm64"
chmod +x "$RELEASE_DIR/ios-use-darwin-arm64"
cp "$ROOT_DIR/driver/build/driver.ipa" "$RELEASE_DIR/driver.ipa"
cp "$ROOT_DIR/driver/build/driver-sim.ipa" "$RELEASE_DIR/driver-sim.ipa"
RUNTIME_SOURCE="$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
if [ ! -x "$RUNTIME_SOURCE/IOSUsePlayRuntime" ]; then
  echo "[release-build] ERROR: missing prebuilt Mac Runtime: $RUNTIME_SOURCE" >&2
  exit 1
fi
if [ ! -f "$RUNTIME_SOURCE/Info.plist" ] &&
   [ ! -f "$RUNTIME_SOURCE/Versions/A/Resources/Info.plist" ]; then
  echo "[release-build] ERROR: Mac Runtime is missing Info.plist" >&2
  exit 1
fi
/usr/bin/codesign --verify --strict "$RUNTIME_SOURCE"
runtime_source_manifest "$ROOT_DIR" "$RUNTIME_INPUTS_AFTER"
if ! cmp -s "$RUNTIME_INPUTS_BEFORE" "$RUNTIME_INPUTS_AFTER"; then
  echo "[release-build] ERROR: Runtime build inputs changed while release binaries were being built" >&2
  diff -u --label "Runtime inputs before build" --label "Runtime inputs after build" \
    "$RUNTIME_INPUTS_BEFORE" "$RUNTIME_INPUTS_AFTER" >&2 || true
  exit 1
fi

PLAYCOVER_RESOURCES_STAGE="$RELEASE_TEMP/playcover-resources"
RUNTIME_STAGE="$PLAYCOVER_RESOURCES_STAGE/IOSUsePlayRuntime.framework"
FRIDA_ENGINE_STAGE="$PLAYCOVER_RESOURCES_STAGE/IOSUseFridaEngine.framework"
mkdir -p "$PLAYCOVER_RESOURCES_STAGE"
cp -R "$RUNTIME_SOURCE" "$RUNTIME_STAGE"
/usr/bin/codesign --verify --strict "$RUNTIME_STAGE"
echo "[release-build] Building pinned Frida Engine resource..."
FRIDA_GUM_BUILD_ROOT="$RELEASE_TEMP/frida-gum-build"
IOS_USE_FRIDA_GUM_BUILD_ROOT="$FRIDA_GUM_BUILD_ROOT" \
IOS_USE_FRIDA_SOURCE_CACHE="$RELEASE_TEMP/frida-source-cache" \
  bash "$ROOT_DIR/scripts/build_playcover_frida_engine.sh" \
    --build-gum \
    --output "$FRIDA_ENGINE_STAGE" \
    --replace
/usr/bin/codesign --verify --strict "$FRIDA_ENGINE_STAGE"
FRIDA_NOTICE_STAGE="$FRIDA_ENGINE_STAGE/Resources/ThirdPartyNotices.txt"
if [[ ! -s "$FRIDA_NOTICE_STAGE" || -L "$FRIDA_NOTICE_STAGE" ]]; then
  echo "[release-build] ERROR: Frida Engine lacks its static-dependency notices" >&2
  exit 1
fi
shopt -s nullglob
FRIDA_SOURCE_ROOTS=("$RELEASE_TEMP/frida-source-cache"/*)
shopt -u nullglob
if [[ "${#FRIDA_SOURCE_ROOTS[@]}" -ne 1 ||
      ! -d "${FRIDA_SOURCE_ROOTS[0]}" ]]; then
  echo "[release-build] ERROR: release build did not retain one pinned Frida source checkout" >&2
  exit 1
fi
FRIDA_SOURCE_ROOT="${FRIDA_SOURCE_ROOTS[0]}"
python3 "$ROOT_DIR/scripts/frida_distribution.py" validate-source \
  --repository-root "$ROOT_DIR" \
  --source-root "$FRIDA_SOURCE_ROOT"
FRIDA_SOURCE_COMMIT="$(
  plutil -extract IOSUseFridaSourceCommit raw "$FRIDA_ENGINE_STAGE/Info.plist"
)"
if [[ "$FRIDA_SOURCE_COMMIT" != "$(basename "$FRIDA_SOURCE_ROOT")" ]]; then
  echo "[release-build] ERROR: Frida Engine and retained source checkout disagree" >&2
  exit 1
fi
for local_path in "$ROOT_DIR/" "$HOME/"; do
  if LC_ALL=C rg --text --hidden --no-ignore --fixed-strings --quiet -- \
      "$local_path" "$PLAYCOVER_RESOURCES_STAGE"; then
    echo \
      "[release-build] ERROR: Mac resources embed local build path: $local_path" \
      >&2
    exit 1
  fi
done
PLAYCOVER_RESOURCES_ASSET="ios-use-mac-resources.tar.gz"
(
  cd "$PLAYCOVER_RESOURCES_STAGE"
  COPYFILE_DISABLE=1 tar -czf "$RELEASE_DIR/$PLAYCOVER_RESOURCES_ASSET" \
    IOSUsePlayRuntime.framework IOSUseFridaEngine.framework
)

require_clean_source_tree "after the build"
CHANGELOG_SOURCE="$ROOT_DIR/release-notes/CHANGELOG-v$ACTUAL_VERSION.md"
if [ ! -s "$CHANGELOG_SOURCE" ]; then
  echo "[release-build] ERROR: missing or empty release changelog: $CHANGELOG_SOURCE" >&2
  exit 1
fi

for asset in \
  ios-use-darwin-arm64 \
  driver.ipa \
  driver-sim.ipa \
  "$PLAYCOVER_RESOURCES_ASSET"; do
  if [ ! -s "$RELEASE_DIR/$asset" ]; then
    echo "[release-build] ERROR: missing or empty release asset: $asset" >&2
    exit 1
  fi
done

(
  cd "$RELEASE_DIR"
  shasum -a 256 \
    ios-use-darwin-arm64 \
    driver.ipa \
    driver-sim.ipa \
    "$PLAYCOVER_RESOURCES_ASSET" > SHA256SUMS
)

EXPECTED_ASSETS="$(printf '%s\n' \
  SHA256SUMS \
  driver-sim.ipa \
  driver.ipa \
  ios-use-darwin-arm64 \
  ios-use-mac-resources.tar.gz)"
ACTUAL_ASSETS="$(
  cd "$RELEASE_DIR"
  printf '%s\n' * | LC_ALL=C sort
)"
if [[ "$ACTUAL_ASSETS" != "$EXPECTED_ASSETS" ]]; then
  echo "[release-build] ERROR: release directory is not the exact five-asset set" >&2
  printf '%s\n' "$ACTUAL_ASSETS" >&2
  exit 1
fi

STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[release-build] Asset staging completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
echo "[release-build] Assets ready under $RELEASE_DIR"
TOTAL_ELAPSED=$(($(date +%s) - RELEASE_STARTED_AT))
printf '[release-build] Total completed in %dm%02ds\n' "$((TOTAL_ELAPSED / 60))" "$((TOTAL_ELAPSED % 60))"
