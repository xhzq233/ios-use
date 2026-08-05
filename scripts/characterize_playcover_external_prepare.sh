#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
XCTEST_FILTER="PlayCoverExternalPrepareDifferentialTests/testConfiguredExternalAppWritesDiagnosticCharacterization"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/characterize_playcover_external_prepare.sh \
  --scenario <scenario.json> \
  --runtime <IOSUsePlayRuntime.framework> \
  --playtools <PlayTools.framework> \
  --work-root <fresh-absolute-directory> \
  --report <fresh-absolute-json-path> \
  --commit <lowercase-40-digit-git-commit>
EOF
}

fail_usage() {
  echo \
    "[playcover-external-prepare-characterization] ERROR: $*" \
    >&2
  usage
  exit 64
}

SCENARIO=""
RUNTIME=""
PLAYTOOLS=""
WORK_ROOT=""
REPORT_PATH=""
COMMIT=""

set_once() {
  local name="$1"
  local current="$2"
  local value="$3"
  if [[ -n "$current" ]]; then
    fail_usage "$name was provided more than once"
  fi
  if [[ -z "$value" ]]; then
    fail_usage "$name requires a non-empty value"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      [[ $# -ge 2 ]] || fail_usage "--scenario requires a value"
      set_once "--scenario" "$SCENARIO" "$2"
      SCENARIO="$2"
      shift 2
      ;;
    --runtime)
      [[ $# -ge 2 ]] || fail_usage "--runtime requires a value"
      set_once "--runtime" "$RUNTIME" "$2"
      RUNTIME="$2"
      shift 2
      ;;
    --playtools)
      [[ $# -ge 2 ]] || fail_usage "--playtools requires a value"
      set_once "--playtools" "$PLAYTOOLS" "$2"
      PLAYTOOLS="$2"
      shift 2
      ;;
    --work-root)
      [[ $# -ge 2 ]] || fail_usage "--work-root requires a value"
      set_once "--work-root" "$WORK_ROOT" "$2"
      WORK_ROOT="$2"
      shift 2
      ;;
    --report)
      [[ $# -ge 2 ]] || fail_usage "--report requires a value"
      set_once "--report" "$REPORT_PATH" "$2"
      REPORT_PATH="$2"
      shift 2
      ;;
    --commit)
      [[ $# -ge 2 ]] || fail_usage "--commit requires a value"
      set_once "--commit" "$COMMIT" "$2"
      COMMIT="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail_usage "unknown argument: $1"
      ;;
  esac
done

for required in \
  SCENARIO \
  RUNTIME \
  PLAYTOOLS \
  WORK_ROOT \
  REPORT_PATH \
  COMMIT; do
  if [[ -z "${!required}" ]]; then
    fail_usage "missing required argument: $required"
  fi
done

if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  fail_usage "--commit must be a lowercase 40-digit Git commit"
fi
if [[ "$WORK_ROOT" == *$'\n'* || "$WORK_ROOT" == *$'\r'* ]]; then
  fail_usage "--work-root must not contain CR or LF"
fi
for path in \
  "$SCENARIO" \
  "$RUNTIME" \
  "$PLAYTOOLS" \
  "$WORK_ROOT" \
  "$REPORT_PATH"; do
  if [[ "$path" != /* ]]; then
    fail_usage "all configured paths must be absolute: $path"
  fi
done

for tool in \
  /bin/ln \
  /usr/bin/codesign \
  /usr/bin/git \
  /usr/bin/plutil \
  /usr/bin/shasum \
  /usr/bin/stat \
  /usr/bin/xcrun; do
  if [[ ! -x "$tool" ]]; then
    echo \
      "[playcover-external-prepare-characterization] ERROR: missing $tool" \
      >&2
    exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: missing jq" \
    >&2
  exit 1
fi

if [[ ! -f "$SCENARIO" || -L "$SCENARIO" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: scenario must be a regular non-symlink file" \
    >&2
  exit 78
fi
if [[ ! -d "$RUNTIME" || -L "$RUNTIME" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: Runtime must be a non-symlink directory" \
    >&2
  exit 78
fi
if [[ ! -d "$PLAYTOOLS" || -L "$PLAYTOOLS" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: PlayTools must be a non-symlink directory" \
    >&2
  exit 78
fi
if [[ -e "$WORK_ROOT" || -L "$WORK_ROOT" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: work root must be a fresh path" \
    >&2
  exit 78
fi
if [[ -e "$REPORT_PATH" || -L "$REPORT_PATH" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: refusing to replace the report" \
    >&2
  exit 78
fi
if [[ ! -d "$(dirname "$WORK_ROOT")" ]] ||
   [[ ! -d "$(dirname "$REPORT_PATH")" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: work and report parent directories must exist" \
    >&2
  exit 78
fi

SCENARIO="$(
  cd "$(dirname "$SCENARIO")" &&
    pwd -P
)/$(basename "$SCENARIO")"
RUNTIME="$(cd "$RUNTIME" && pwd -P)"
PLAYTOOLS="$(cd "$PLAYTOOLS" && pwd -P)"
WORK_PARENT="$(cd "$(dirname "$WORK_ROOT")" && pwd -P)"
WORK_ROOT="$WORK_PARENT/$(basename "$WORK_ROOT")"
WORK_ROOT_SHA256="$(
  printf '%s' "$WORK_ROOT" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)"
REPORT_PARENT="$(cd "$(dirname "$REPORT_PATH")" && pwd -P)"
REPORT_PATH="$REPORT_PARENT/$(basename "$REPORT_PATH")"

case "$WORK_ROOT/" in
  "$ROOT_DIR/"*)
    echo \
      "[playcover-external-prepare-characterization] ERROR: work root must be outside the checkout" \
      >&2
    exit 78
    ;;
esac
case "$REPORT_PATH" in
  "$ROOT_DIR"/*)
    echo \
      "[playcover-external-prepare-characterization] ERROR: report must be outside the checkout" \
      >&2
    exit 78
    ;;
esac
if [[ "$WORK_ROOT" == "$REPORT_PATH" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: work root and report must be distinct paths" \
    >&2
  exit 78
fi

if [[ "$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: --commit does not identify the current checkout HEAD" \
    >&2
  exit 78
fi
if ! /usr/bin/git -C "$ROOT_DIR" diff \
    --quiet --no-ext-diff --; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: tracked working tree differs from the index" \
    >&2
  exit 78
fi
if ! /usr/bin/git -C "$ROOT_DIR" diff \
    --cached --quiet --no-ext-diff "$COMMIT" --; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: index differs from the committed HEAD" \
    >&2
  exit 78
fi
if [[ -n "$(
  /usr/bin/git -C "$ROOT_DIR" \
    ls-files --others --exclude-standard
)" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: checkout has untracked non-ignored files" \
    >&2
  exit 78
fi

CANDIDATE_DIR="$(
  mktemp -d \
    "$REPORT_PARENT/.external-prepare-characterization.XXXXXX"
)"
CANDIDATE_PATH="$CANDIDATE_DIR/report.json"
SCRATCH_PATH="$(
  mktemp -d \
    "/tmp/ios-use-external-characterization-build.XXXXXX"
)"
TEST_LOG="$(
  mktemp \
    "/tmp/ios-use-external-characterization-test.XXXXXX"
)"

cleanup() {
  rm -f "$CANDIDATE_PATH" "$TEST_LOG"
  case "$SCRATCH_PATH" in
    /tmp/ios-use-external-characterization-build.*|\
    /private/tmp/ios-use-external-characterization-build.*)
      /bin/rm -rf -- "$SCRATCH_PATH"
      ;;
  esac
  rmdir "$CANDIDATE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo \
  "[playcover-external-prepare-characterization] collecting raw differences"
(
  /usr/bin/env -i \
    HOME="${HOME:?HOME is required}" \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR=/tmp \
    IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_SCENARIO="$SCENARIO" \
    IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_RUNTIME="$RUNTIME" \
    IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_PLAYTOOLS="$PLAYTOOLS" \
    IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_WORK_ROOT="$WORK_ROOT" \
    IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_REPORT="$CANDIDATE_PATH" \
    IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_COMMIT="$COMMIT" \
    swift test \
      --package-path "$ROOT_DIR/swift-cli" \
      --scratch-path "$SCRATCH_PATH" \
      --filter "$XCTEST_FILTER"
) 2>&1 | tee "$TEST_LOG"

sentinel="Test Case '-[IOSUseCLITests.PlayCoverExternalPrepareDifferentialTests testConfiguredExternalAppWritesDiagnosticCharacterization]' passed"
if ! grep -Fq "$sentinel" "$TEST_LOG"; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: configured XCTest did not complete successfully" \
    >&2
  exit 1
fi
if [[ ! -s "$CANDIDATE_PATH" || -L "$CANDIDATE_PATH" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: diagnostic report was not written" \
    >&2
  exit 1
fi
if [[ "$(/usr/bin/stat -f '%HT:%Lp:%u:%l' "$CANDIDATE_PATH")" \
    != "Regular File:600:$(id -u):1" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: candidate report is not an owner-only single-link regular file" \
    >&2
  exit 1
fi
if [[ "$(
  find "$CANDIDATE_DIR" -mindepth 1 -maxdepth 1 |
    wc -l |
    tr -d ' '
)" != "1" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: XCTest wrote unexpected candidate artifacts" \
    >&2
  exit 1
fi

if ! jq -e \
  --arg commit "$COMMIT" \
  --arg work_root "$WORK_ROOT_SHA256" \
  --arg work_root_path "$WORK_ROOT" '
    def lower_sha256:
      type == "string" and test("^[0-9a-f]{64}$");
    def forbidden_word:
      ascii_downcase
      | test("pass|profile|allowance|attestation");
    def all_key_names:
      [paths | .[] | select(type == "string")];
    def all_string_values:
      [.. | select(type == "string")];
    .schemaVersion == 2 and
    .scope == "external-app-structural-v2" and
    .kind == "playcover-external-prepare-characterization" and
    .disposition == "diagnostic-only" and
    .repositoryCommit == $commit and
    .workRootSHA256 == $work_root and
    (.source.contentSHA256 | lower_sha256) and
    (.source.executableSHA256 | lower_sha256) and
    (.source.inventorySelectorsSHA256 | lower_sha256) and
    (.source.objectSelectorsSHA256 | lower_sha256) and
    (.source.sliceSelectorsSHA256 | lower_sha256) and
    (.source.bundleIdentifier | type == "string" and length > 0) and
    (
      .source.mainExecutableRelativePath
      | type == "string" and length > 0
    ) and
    .source.inventoryCount > 0 and
    .source.objectCount > 0 and
    .source.sliceCount > 0 and
    .sourceState.unchanged == true and
    (.sourceState.scenarioSHA256 | lower_sha256) and
    .sourceState.inputContentSHA256 == .source.contentSHA256 and
    .sourceState.inputContentSHA256 ==
      .sourceState.snapshotContentSHA256 and
    .sourceState.inputContentSHA256 ==
      .sourceState.recomputedAfterPrepareSHA256 and
    (.runtime.inputTreeSHA256 | lower_sha256) and
    (.runtime.inputExecutableSHA256 | lower_sha256) and
    (.runtime.signedProjectionTreeSHA256 | lower_sha256) and
    (
      .runtime.signedProjectionExecutableSHA256
      | lower_sha256
    ) and
    .runtime.outputFrameworkRelativePath ==
      "Frameworks/IOSUsePlayRuntime.framework" and
    .runtime.outputExecutableRelativePath ==
      "Frameworks/IOSUsePlayRuntime.framework/Versions/A/IOSUsePlayRuntime" and
    (.playTools.inputTreeSHA256 | lower_sha256) and
    (.playTools.signedPluginTreeSHA256 | lower_sha256) and
    (.playTools.signedPluginExecutableSHA256 | lower_sha256) and
    .playTools.outputPluginRelativePath ==
      "PlugIns/AKInterface.bundle" and
    .playTools.outputPluginExecutableRelativePath ==
      "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface" and
    (
      .revisions.playCover
      | type == "string" and test("^[0-9a-f]{40}$")
    ) and
    (
      .revisions.inject
      | type == "string" and test("^[0-9a-f]{40}$")
    ) and
    (.revisions.rules | lower_sha256) and
    (.revisions.prepare | type == "string" and length > 0) and
    .inputs.runtimeUnchanged == true and
    .inputs.playToolsUnchanged == true and
    .inputs.runtimeInputTreeSHA256 ==
      .runtime.inputTreeSHA256 and
    .inputs.runtimeSignedProjectionTreeSHA256 ==
      .runtime.signedProjectionTreeSHA256 and
    .inputs.playToolsInputTreeSHA256 ==
      .playTools.inputTreeSHA256 and
    .inputs.playToolsSignedPluginTreeSHA256 ==
      .playTools.signedPluginTreeSHA256 and
    (.pinnedOutputSHA256 | lower_sha256) and
    (.iosUseOutputSHA256 | lower_sha256) and
    .normalizationMode == "external-app-managed-paths-v1" and
    (.differences | type == "array") and
    all(
      .differences[];
      (.relativePath | type == "string" and length > 0) and
      (.field | type == "string" and length > 0) and
      (
        .pinnedValue == null or
        (.pinnedValue | type == "string")
      ) and
      (
        .iosUseValue == null or
        (.iosUseValue | type == "string")
      )
    ) and
    (
      all_key_names
      | all(
          .[];
          (
            ascii_downcase
            | test("reason|symbol")
            | not
          )
        )
    ) and
    (
      all_key_names + all_string_values
      | all(.[]; forbidden_word | not)
    ) and
    (
      all_key_names + all_string_values
      | all(.[]; contains($work_root_path) | not)
    )
  ' "$CANDIDATE_PATH" >/dev/null; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: candidate diagnostic report violates its fixed schema" \
    >&2
  exit 1
fi

CANDIDATE_SHA256="$(
  /usr/bin/shasum -a 256 "$CANDIDATE_PATH" |
    /usr/bin/awk '{print $1}'
)"
if ! /bin/ln "$CANDIDATE_PATH" "$REPORT_PATH"; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: could not publish the report without overwrite" \
    >&2
  exit 78
fi
cleanup
trap - EXIT

if [[ "$(/usr/bin/stat -f '%HT:%Lp:%u:%l' "$REPORT_PATH")" \
    != "Regular File:600:$(id -u):1" ]] ||
   [[ "$(
     /usr/bin/shasum -a 256 "$REPORT_PATH" |
       /usr/bin/awk '{print $1}'
   )" != "$CANDIDATE_SHA256" ]]; then
  echo \
    "[playcover-external-prepare-characterization] ERROR: published report identity changed" \
    >&2
  exit 1
fi

echo \
  "[playcover-external-prepare-characterization] diagnostic report retained: $REPORT_PATH"
