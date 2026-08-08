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
    echo "[release-build] ERROR: source tree is dirty $phase; refusing binaries whose corresponding-source archive would differ." >&2
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

verify_file_set() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if ! cmp -s "$expected" "$actual"; then
    echo "[release-build] ERROR: $description file set differs from its audited source" >&2
    diff -u --label "$description expected" --label "$description actual" \
      "$expected" "$actual" >&2 || true
    exit 1
  fi
}

require_clean_source_tree "before the build"

echo "[release-build] Auditing pinned PlayCover upstreams..."
bash "$ROOT_DIR/scripts/audit_playcover_upstreams.sh" --cache-dir "$UPSTREAM_CACHE"

RUNTIME_INPUTS_BEFORE="$RELEASE_TEMP/runtime-inputs.before"
RUNTIME_INPUTS_AFTER="$RELEASE_TEMP/runtime-inputs.after"
runtime_source_manifest "$ROOT_DIR" "$RUNTIME_INPUTS_BEFORE"
RUNTIME_SOURCE_SHA256="$(shasum -a 256 "$RUNTIME_INPUTS_BEFORE" | awk '{print $1}')"

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
RULES_SOURCE="$ROOT_DIR/ThirdParty/PlayCover/PlayCover/Rules/default.yaml"
RULES_STAGE="$PLAYCOVER_RESOURCES_STAGE/default-sandbox-rules.yaml"
RULES_EXPECTED_SHA256="$(
  sed -n \
    '/public static let defaultRulesRevision/{n;s/.*"\([0-9a-f]*\)".*/\1/p;}' \
    "$ROOT_DIR/ThirdParty/PlayCover/PlayCover/Headless/PlayCoverUpstreamEngine.swift"
)"
RULES_SHA256="$(shasum -a 256 "$RULES_SOURCE" | awk '{print $1}')"
if [[ -z "$RULES_EXPECTED_SHA256" ||
      "$RULES_SHA256" != "$RULES_EXPECTED_SHA256" ]]; then
  echo "[release-build] ERROR: sandbox rules do not match the pinned Runtime descriptor" >&2
  exit 1
fi
mkdir -p "$PLAYCOVER_RESOURCES_STAGE"
cp -R "$RUNTIME_SOURCE" "$RUNTIME_STAGE"
cp "$RULES_SOURCE" "$RULES_STAGE"
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
FRIDA_VERSION="$(
  plutil -extract CFBundleShortVersionString raw "$FRIDA_ENGINE_STAGE/Info.plist"
)"
if [[ "$FRIDA_SOURCE_COMMIT" != "$(basename "$FRIDA_SOURCE_ROOT")" ]]; then
  echo "[release-build] ERROR: Frida Engine and retained source checkout disagree" >&2
  exit 1
fi
FRIDA_NOTICE_SHA256="$(shasum -a 256 "$FRIDA_NOTICE_STAGE" | awk '{print $1}')"
FRIDA_ENGINE_BUNDLE_DIGEST="$(
    python3 - "$FRIDA_ENGINE_STAGE" <<'PY'
import hashlib
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
files = []
for path in root.rglob('*'):
    if path.is_file():
        files.append((path.relative_to(root).as_posix(), path.read_bytes()))
hasher = hashlib.sha256()
for relative, data in sorted(files):
    encoded = relative.encode('utf-8')
    hasher.update(struct.pack('>Q', len(encoded)))
    hasher.update(encoded)
    hasher.update(struct.pack('>Q', len(data)))
    hasher.update(data)
print(hasher.hexdigest())
PY
)"
FRIDA_ENGINE_BUNDLE_SIZE="$(
    python3 - "$FRIDA_ENGINE_STAGE" <<'PY'
import pathlib
import sys
print(sum(path.stat().st_size for path in pathlib.Path(sys.argv[1]).rglob('*') if path.is_file()))
PY
)"
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
    IOSUsePlayRuntime.framework IOSUseFridaEngine.framework \
    default-sandbox-rules.yaml
)
PLAYCOVER_RESOURCES_ARCHIVE_SHA256="$(
  shasum -a 256 "$RELEASE_DIR/$PLAYCOVER_RESOURCES_ASSET" |
    awk '{print $1}'
)"

SOURCE_ARCHIVE="ios-use-v$ACTUAL_VERSION-corresponding-source.tar.gz"
SOURCE_PREFIX="ios-use-v$ACTUAL_VERSION/"
SOURCE_TAR="$RELEASE_DIR/.corresponding-source.tar"
SOURCE_EXPECTED="$RELEASE_DIR/.corresponding-source.expected"
SOURCE_ACTUAL="$RELEASE_DIR/.corresponding-source.actual"
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
require_clean_source_tree "after the build"

SOURCE_STAGE_PARENT="$RELEASE_TEMP/source-asset"
SOURCE_STAGE="$SOURCE_STAGE_PARENT/${SOURCE_PREFIX%/}"
mkdir -p "$SOURCE_STAGE_PARENT"
git -C "$ROOT_DIR" archive --format=tar \
  --prefix="$SOURCE_PREFIX" HEAD |
  tar -xf - -C "$SOURCE_STAGE_PARENT"

git -C "$ROOT_DIR" ls-tree -r --name-only HEAD |
  LC_ALL=C sort > "$RELEASE_TEMP/project-source.expected"
(
  cd "$SOURCE_STAGE"
  find . \( -type f -o -type l \) -print |
    sed 's#^\./##' |
    LC_ALL=C sort
) > "$RELEASE_TEMP/project-source.actual"
verify_file_set "Git HEAD source" \
  "$RELEASE_TEMP/project-source.expected" "$RELEASE_TEMP/project-source.actual"

YAMS_COMMIT="$(
  sed -n 's/^- Pinned commit: `\([0-9a-f][0-9a-f]*\)`$/\1/p' \
    "$ROOT_DIR/ThirdParty/Yams/PROVENANCE.md"
)"
if [[ ! "$YAMS_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[release-build] ERROR: audited Yams provenance has no unique full commit" >&2
  exit 1
fi
YAMS_CHECKOUT="$UPSTREAM_CACHE/Yams"
if [[ ! -d "$YAMS_CHECKOUT/.git" ||
      "$(git -C "$YAMS_CHECKOUT" rev-parse HEAD)" != "$YAMS_COMMIT" ]]; then
  echo "[release-build] ERROR: audited pinned Yams checkout is unavailable" >&2
  exit 1
fi
YAMS_SOURCE="$SOURCE_STAGE/ThirdParty/Yams/upstream-source"
mkdir -p "$YAMS_SOURCE"
git -C "$YAMS_CHECKOUT" archive --format=tar "$YAMS_COMMIT" |
  tar -xf - -C "$YAMS_SOURCE"
git -C "$YAMS_CHECKOUT" ls-tree -r --name-only "$YAMS_COMMIT" |
  LC_ALL=C sort > "$RELEASE_TEMP/yams-source.expected"
(
  cd "$YAMS_SOURCE"
  find . \( -type f -o -type l \) -print |
    sed 's#^\./##' |
    LC_ALL=C sort
) > "$RELEASE_TEMP/yams-source.actual"
verify_file_set "Yams $YAMS_COMMIT source" \
  "$RELEASE_TEMP/yams-source.expected" "$RELEASE_TEMP/yams-source.actual"

FRIDA_SOURCE="$SOURCE_STAGE/ThirdParty/Frida/upstream-source"
FRIDA_SOURCE_FILES="$RELEASE_TEMP/frida-source.files"
python3 "$ROOT_DIR/scripts/frida_distribution.py" stage-source \
  --repository-root "$ROOT_DIR" \
  --source-root "$FRIDA_SOURCE_ROOT" \
  --output "$FRIDA_SOURCE" \
  --file-list-output "$FRIDA_SOURCE_FILES"
FRIDA_SOURCE_MANIFEST="$FRIDA_SOURCE/FRIDA-SOURCE-MANIFEST.txt"
if [[ ! -s "$FRIDA_SOURCE_MANIFEST" ]]; then
  echo "[release-build] ERROR: staged Frida source lacks its content manifest" >&2
  exit 1
fi
FRIDA_SOURCE_MANIFEST_SHA256="$(
  shasum -a 256 "$FRIDA_SOURCE_MANIFEST" | awk '{print $1}'
)"

runtime_source_manifest "$SOURCE_STAGE" "$RELEASE_TEMP/runtime-inputs.archived"
if ! cmp -s "$RUNTIME_INPUTS_BEFORE" "$RELEASE_TEMP/runtime-inputs.archived"; then
  echo "[release-build] ERROR: archived Runtime sources do not match the freshly built Runtime inputs" >&2
  diff -u --label "fresh Runtime inputs" --label "archived Runtime inputs" \
    "$RUNTIME_INPUTS_BEFORE" "$RELEASE_TEMP/runtime-inputs.archived" >&2 || true
  exit 1
fi

printf '%s\n' \
  "ios-use source commit: $SOURCE_COMMIT" \
  "Yams source commit: $YAMS_COMMIT" \
  "Frida Gum source commit: $FRIDA_SOURCE_COMMIT" \
  "Frida source closure manifest SHA-256: $FRIDA_SOURCE_MANIFEST_SHA256" \
  "Mac Runtime input manifest SHA-256: $RUNTIME_SOURCE_SHA256" \
  > "$SOURCE_STAGE/CORRESPONDING-SOURCE-MANIFEST.txt"

(
  cd "$SOURCE_STAGE_PARENT"
  COPYFILE_DISABLE=1 tar -cf "$SOURCE_TAR" "${SOURCE_PREFIX%/}"
)
{
  git -C "$ROOT_DIR" ls-tree -r --name-only HEAD |
    sed "s#^#$SOURCE_PREFIX#"
  git -C "$YAMS_CHECKOUT" ls-tree -r --name-only "$YAMS_COMMIT" |
    sed "s#^#${SOURCE_PREFIX}ThirdParty/Yams/upstream-source/#"
  sed \
    "s#^#${SOURCE_PREFIX}ThirdParty/Frida/upstream-source/#" \
    "$FRIDA_SOURCE_FILES"
  printf '%sCORRESPONDING-SOURCE-MANIFEST.txt\n' "$SOURCE_PREFIX"
} |
  LC_ALL=C sort > "$SOURCE_EXPECTED"
tar -tf "$SOURCE_TAR" |
  sed '/\/$/d' |
  LC_ALL=C sort > "$SOURCE_ACTUAL"
verify_file_set "corresponding-source archive" "$SOURCE_EXPECTED" "$SOURCE_ACTUAL"
gzip -n < "$SOURCE_TAR" > "$RELEASE_DIR/$SOURCE_ARCHIVE"
rm -f "$SOURCE_TAR" "$SOURCE_EXPECTED" "$SOURCE_ACTUAL"
SOURCE_ARCHIVE_SHA256="$(
  shasum -a 256 "$RELEASE_DIR/$SOURCE_ARCHIVE" |
    awk '{print $1}'
)"

cp "$ROOT_DIR/LICENSE" "$RELEASE_DIR/LICENSE"
cp "$ROOT_DIR/ThirdParty/PlayCover/LICENSE" "$RELEASE_DIR/PLAYCOVER-LICENSE-GPL-3.0"
cp "$ROOT_DIR/playcover-runtime/PlayTools/LICENSE" "$RELEASE_DIR/PLAYTOOLS-LICENSE-AGPL-3.0"
cp "$ROOT_DIR/ThirdParty/inject/LICENSE" "$RELEASE_DIR/INJECT-LICENSE-GPL-3.0"
cp "$ROOT_DIR/ThirdParty/Yams/LICENSE" "$RELEASE_DIR/YAMS-LICENSE-MIT"
cp "$ROOT_DIR/ThirdParty/LICENSES.md" "$RELEASE_DIR/THIRD-PARTY-LICENSES.md"
cp "$FRIDA_NOTICE_STAGE" \
  "$RELEASE_DIR/FRIDA-STATIC-DEPENDENCY-NOTICES.txt"
BUILD_MANIFEST_ASSET="MAC-BACKEND-BUILD-MANIFEST-v$ACTUAL_VERSION.txt"
{
  printf 'ios-use source commit: %s\n' "$SOURCE_COMMIT"
  printf 'Yams source commit: %s\n' "$YAMS_COMMIT"
  printf 'Mac Runtime input manifest SHA-256: %s\n' "$RUNTIME_SOURCE_SHA256"
  printf 'Mac backend resources archive SHA-256: %s\n' "$PLAYCOVER_RESOURCES_ARCHIVE_SHA256"
  printf 'Mac sandbox rules SHA-256: %s\n' "$RULES_SHA256"
  printf 'Frida version: %s\n' "$FRIDA_VERSION"
  printf 'Frida Gum source commit: %s\n' "$FRIDA_SOURCE_COMMIT"
  printf 'Frida source closure manifest SHA-256: %s\n' \
    "$FRIDA_SOURCE_MANIFEST_SHA256"
  printf 'Frida static-dependency notices SHA-256: %s\n' \
    "$FRIDA_NOTICE_SHA256"
  printf 'Frida Engine ABI: %s\n' 'ios-use-frida-engine-cabi-v2'
  printf 'Frida Engine framework SHA-256: %s\n' "$FRIDA_ENGINE_BUNDLE_DIGEST"
  printf 'Frida Engine framework bytes: %s\n' "$FRIDA_ENGINE_BUNDLE_SIZE"
  printf 'Corresponding-source archive SHA-256: %s\n' "$SOURCE_ARCHIVE_SHA256"
} > "$RELEASE_DIR/$BUILD_MANIFEST_ASSET"
PROVENANCE_ASSET="MAC-BACKEND-PROVENANCE-v$ACTUAL_VERSION.md"
{
  printf '# Mac backend release provenance\n\n'
  printf 'This release packages `IOSUsePlayRuntime.framework`, the always-available `IOSUseFridaEngine.framework`, and the pinned sandbox rules as read-only resources under `share/ios-use/mac/`.\n\n'
  printf 'The complete corresponding source for this exact release is `%s`; it includes the complete pinned Yams tree and the Frida GumJS static source closure.\n\n' "$SOURCE_ARCHIVE"
  printf 'Fresh Runtime/source/archive digests are recorded in `%s`.\n\n' "$BUILD_MANIFEST_ASSET"
  for provenance in \
    "$ROOT_DIR/ThirdParty/PlayCover/PROVENANCE.md" \
    "$ROOT_DIR/playcover-runtime/PlayTools/PROVENANCE.md" \
    "$ROOT_DIR/ThirdParty/inject/PROVENANCE.md" \
    "$ROOT_DIR/ThirdParty/Yams/PROVENANCE.md" \
    "$ROOT_DIR/ThirdParty/Frida/PROVENANCE.md"; do
    printf '\n---\n\n'
    sed -n '1,$p' "$provenance"
  done
} > "$RELEASE_DIR/$PROVENANCE_ASSET"
CHANGELOG_ASSET="CHANGELOG-v$ACTUAL_VERSION.md"
CHANGELOG_SOURCE="$ROOT_DIR/release-notes/$CHANGELOG_ASSET"
if [ ! -s "$CHANGELOG_SOURCE" ]; then
  echo "[release-build] ERROR: missing or empty release changelog: $CHANGELOG_SOURCE" >&2
  exit 1
fi
cp "$CHANGELOG_SOURCE" "$RELEASE_DIR/$CHANGELOG_ASSET"

for asset in \
  ios-use-darwin-arm64 \
  driver.ipa \
  driver-sim.ipa \
  "$PLAYCOVER_RESOURCES_ASSET" \
  "$SOURCE_ARCHIVE" \
  LICENSE \
  PLAYCOVER-LICENSE-GPL-3.0 \
  PLAYTOOLS-LICENSE-AGPL-3.0 \
  INJECT-LICENSE-GPL-3.0 \
  YAMS-LICENSE-MIT \
  FRIDA-STATIC-DEPENDENCY-NOTICES.txt \
  THIRD-PARTY-LICENSES.md \
  "$BUILD_MANIFEST_ASSET" \
  "$PROVENANCE_ASSET" \
  "$CHANGELOG_ASSET"; do
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
    "$PLAYCOVER_RESOURCES_ASSET" \
    "$SOURCE_ARCHIVE" \
    LICENSE \
    PLAYCOVER-LICENSE-GPL-3.0 \
    PLAYTOOLS-LICENSE-AGPL-3.0 \
    INJECT-LICENSE-GPL-3.0 \
    YAMS-LICENSE-MIT \
    FRIDA-STATIC-DEPENDENCY-NOTICES.txt \
    THIRD-PARTY-LICENSES.md \
    "$BUILD_MANIFEST_ASSET" \
    "$PROVENANCE_ASSET" \
    "$CHANGELOG_ASSET" > SHA256SUMS
)

STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[release-build] Asset staging completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
echo "[release-build] Assets ready under $RELEASE_DIR"
TOTAL_ELAPSED=$(($(date +%s) - RELEASE_STARTED_AT))
printf '[release-build] Total completed in %dm%02ds\n' "$((TOTAL_ELAPSED / 60))" "$((TOTAL_ELAPSED % 60))"
