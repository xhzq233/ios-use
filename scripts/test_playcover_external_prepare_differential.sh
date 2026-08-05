#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/test_playcover_external_prepare_differential.sh \
  --profile <reviewed-profile.json> \
  --profile-sha256 <lowercase-sha256> \
  --scenario <scenario.json> \
  --runtime <IOSUsePlayRuntime.framework> \
  --playtools <PlayTools.framework> \
  --work-root <fresh-absolute-directory> \
  --attestation <fresh-absolute-json-path> \
  --commit <lowercase-40-digit-git-commit>
EOF
}

fail_usage() {
  echo "[playcover-external-prepare-differential] ERROR: $*" >&2
  usage
  exit 64
}

PROFILE=""
PROFILE_SHA256=""
SCENARIO=""
RUNTIME=""
PLAYTOOLS=""
WORK_ROOT=""
ATTESTATION_PATH=""
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
    --profile)
      [[ $# -ge 2 ]] || fail_usage "--profile requires a value"
      set_once "--profile" "$PROFILE" "$2"
      PROFILE="$2"
      shift 2
      ;;
    --profile-sha256)
      [[ $# -ge 2 ]] || fail_usage "--profile-sha256 requires a value"
      set_once "--profile-sha256" "$PROFILE_SHA256" "$2"
      PROFILE_SHA256="$2"
      shift 2
      ;;
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
    --attestation)
      [[ $# -ge 2 ]] || fail_usage "--attestation requires a value"
      set_once "--attestation" "$ATTESTATION_PATH" "$2"
      ATTESTATION_PATH="$2"
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
  PROFILE \
  PROFILE_SHA256 \
  SCENARIO \
  RUNTIME \
  PLAYTOOLS \
  WORK_ROOT \
  ATTESTATION_PATH \
  COMMIT; do
  if [[ -z "${!required}" ]]; then
    fail_usage "missing required argument: $required"
  fi
done

if [[ ! "$PROFILE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  fail_usage "--profile-sha256 must be a lowercase SHA-256 digest"
fi
if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  fail_usage "--commit must be a lowercase 40-digit Git commit"
fi
if [[ "$WORK_ROOT" == *$'\n'* || "$WORK_ROOT" == *$'\r'* ]]; then
  fail_usage "--work-root must not contain CR or LF"
fi
for path in \
  "$PROFILE" \
  "$SCENARIO" \
  "$RUNTIME" \
  "$PLAYTOOLS" \
  "$WORK_ROOT" \
  "$ATTESTATION_PATH"; do
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
      "[playcover-external-prepare-differential] ERROR: missing $tool" \
      >&2
    exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo \
    "[playcover-external-prepare-differential] ERROR: missing jq" \
    >&2
  exit 1
fi

if [[ ! -f "$PROFILE" || -L "$PROFILE" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: profile must be a regular non-symlink file" \
    >&2
  exit 78
fi
if [[ ! -f "$SCENARIO" || -L "$SCENARIO" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: scenario must be a regular non-symlink file" \
    >&2
  exit 78
fi
if [[ ! -d "$RUNTIME" || -L "$RUNTIME" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: Runtime must be a non-symlink directory" \
    >&2
  exit 78
fi
if [[ ! -d "$PLAYTOOLS" || -L "$PLAYTOOLS" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: PlayTools must be a non-symlink directory" \
    >&2
  exit 78
fi
if [[ -e "$WORK_ROOT" || -L "$WORK_ROOT" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: work root must be a fresh path" \
    >&2
  exit 78
fi
if [[ -e "$ATTESTATION_PATH" || -L "$ATTESTATION_PATH" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: refusing to replace the attestation" \
    >&2
  exit 78
fi

PROFILE="$(cd "$(dirname "$PROFILE")" && pwd -P)/$(basename "$PROFILE")"
SCENARIO="$(cd "$(dirname "$SCENARIO")" && pwd -P)/$(basename "$SCENARIO")"
RUNTIME="$(cd "$RUNTIME" && pwd -P)"
PLAYTOOLS="$(cd "$PLAYTOOLS" && pwd -P)"
WORK_PARENT="$(cd "$(dirname "$WORK_ROOT")" && pwd -P)"
WORK_ROOT="$WORK_PARENT/$(basename "$WORK_ROOT")"
ATTESTATION_PARENT="$(cd "$(dirname "$ATTESTATION_PATH")" && pwd -P)"
ATTESTATION_PATH="$ATTESTATION_PARENT/$(basename "$ATTESTATION_PATH")"

case "$WORK_ROOT/" in
  "$ROOT_DIR/"*)
    echo \
      "[playcover-external-prepare-differential] ERROR: work root must be outside the checkout" \
      >&2
    exit 78
    ;;
esac
case "$ATTESTATION_PATH" in
  "$ROOT_DIR"/*)
    echo \
      "[playcover-external-prepare-differential] ERROR: attestation must be outside the checkout" \
      >&2
    exit 78
    ;;
esac

ACTUAL_PROFILE_SHA256="$(
  /usr/bin/shasum -a 256 "$PROFILE" | /usr/bin/awk '{print $1}'
)"
if [[ "$ACTUAL_PROFILE_SHA256" != "$PROFILE_SHA256" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: profile bytes do not match the reviewed SHA-256" \
    >&2
  exit 78
fi
WORK_ROOT_SHA256="$(
  printf '%s' "$WORK_ROOT" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)"
if ! jq -e '
    .schemaVersion == 2 and
    .scope == "external-app-structural-v2" and
    (
      .workRootSHA256
      | type == "string" and test("^[0-9a-f]{64}$")
    )
  ' "$PROFILE" >/dev/null; then
  echo \
    "[playcover-external-prepare-differential] ERROR: profile must use the external-app-structural-v2 schema with a lowercase work-root SHA-256" \
    >&2
  exit 78
fi
if [[ "$(jq -r '.workRootSHA256' "$PROFILE")" \
    != "$WORK_ROOT_SHA256" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: profile work-root SHA-256 does not match the configured canonical work root" \
    >&2
  exit 78
fi
if [[ "$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: --commit does not identify the current checkout HEAD" \
    >&2
  exit 78
fi
if ! /usr/bin/git -C "$ROOT_DIR" diff \
    --quiet --no-ext-diff --; then
  echo \
    "[playcover-external-prepare-differential] ERROR: tracked working tree differs from the index" \
    >&2
  exit 78
fi
if ! /usr/bin/git -C "$ROOT_DIR" diff \
    --cached --quiet --no-ext-diff "$COMMIT" --; then
  echo \
    "[playcover-external-prepare-differential] ERROR: index differs from the committed HEAD" \
    >&2
  exit 78
fi
if [[ -n "$(
  /usr/bin/git -C "$ROOT_DIR" \
    ls-files --others --exclude-standard
)" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: checkout has untracked non-ignored files" \
    >&2
  exit 78
fi

CANDIDATE_DIR="$(
  mktemp -d \
    "$ATTESTATION_PARENT/.external-prepare-candidate.XXXXXX"
)"
CANDIDATE_PATH="$CANDIDATE_DIR/attestation.json"
SCRATCH_PATH="$(
  mktemp -d \
    "/tmp/ios-use-external-prepare-build.XXXXXX"
)"
TEST_LOG="$(
  mktemp \
    "/tmp/ios-use-external-prepare-test.XXXXXX"
)"

cleanup() {
  rm -f "$CANDIDATE_PATH" "$TEST_LOG"
  case "$SCRATCH_PATH" in
    /tmp/ios-use-external-prepare-build.*|\
    /private/tmp/ios-use-external-prepare-build.*)
      /bin/rm -rf -- "$SCRATCH_PATH"
      ;;
  esac
  rmdir "$CANDIDATE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo \
  "[playcover-external-prepare-differential] running reviewed external-App profile"
(
  /usr/bin/env -i \
    HOME="${HOME:?HOME is required}" \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR=/tmp \
    IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_SCENARIO="$SCENARIO" \
    IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PROFILE="$PROFILE" \
    IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PROFILE_SHA256="$PROFILE_SHA256" \
    IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_RUNTIME="$RUNTIME" \
    IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PLAYTOOLS="$PLAYTOOLS" \
    IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_WORK_ROOT="$WORK_ROOT" \
    IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_ATTESTATION="$CANDIDATE_PATH" \
    IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_COMMIT="$COMMIT" \
    swift test \
      --package-path "$ROOT_DIR/swift-cli" \
      --scratch-path "$SCRATCH_PATH" \
      --filter \
      PlayCoverExternalPrepareDifferentialTests/testConfiguredExternalAppPassesReviewedStructuralProfile
) 2>&1 | tee "$TEST_LOG"

sentinel="Test Case '-[IOSUseCLITests.PlayCoverExternalPrepareDifferentialTests testConfiguredExternalAppPassesReviewedStructuralProfile]' passed"
if ! grep -Fq "$sentinel" "$TEST_LOG"; then
  echo \
    "[playcover-external-prepare-differential] ERROR: configured XCTest did not pass" \
    >&2
  exit 1
fi
if [[ ! -s "$CANDIDATE_PATH" || -L "$CANDIDATE_PATH" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: exact external attestation was not written" \
    >&2
  exit 1
fi
if [[ "$(/usr/bin/stat -f '%HT:%Lp:%u:%l' "$CANDIDATE_PATH")" \
    != "Regular File:600:$(id -u):1" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: candidate attestation is not an owner-only single-link regular file" \
    >&2
  exit 1
fi
if [[ "$(find "$CANDIDATE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" \
    != "1" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: XCTest wrote unexpected candidate artifacts" \
    >&2
  exit 1
fi

if ! jq -e \
  --arg commit "$COMMIT" \
  --arg profile "$PROFILE_SHA256" \
  --arg work_root "$WORK_ROOT_SHA256" '
    def lower_sha256: type == "string" and test("^[0-9a-f]{64}$");
    .schemaVersion == 2 and
    .scope == "external-app-structural-v2" and
    .result == "pass" and
    .repositoryCommit == $commit and
    .profileSHA256 == $profile and
    .workRootSHA256 == $work_root and
    .originalSource.unchanged == true and
    .originalSource.inputContentSHA256 ==
      .originalSource.snapshotContentSHA256 and
    .originalSource.inputContentSHA256 ==
      .originalSource.recomputedAfterPrepareSHA256 and
    (.originalSource.scenarioSHA256 | lower_sha256) and
    .inputs.runtimeUnchanged == true and
    .inputs.playToolsUnchanged == true and
    (.inputs.runtimeInputTreeSHA256 | lower_sha256) and
    (.inputs.runtimeSignedProjectionTreeSHA256 | lower_sha256) and
    (.inputs.playToolsInputTreeSHA256 | lower_sha256) and
    (.inputs.playToolsSignedPluginTreeSHA256 | lower_sha256) and
    .differential.schemaVersion == 1 and
    .differential.scope == "external-app" and
    .differential.result == "pass" and
    .differential.normalization.mode ==
      "external-app-managed-paths-v1" and
    .differential.source.unchanged == true and
    .differential.implementation.algorithm ==
      "embedded-source-closure-plus-loaded-xctest-inode-sha256-v2" and
    .differential.implementation.contentSHA256 ==
      .differential.implementation.embeddedSourceClosureSHA256 and
    (.differential.implementation.testExecutableSHA256 | lower_sha256) and
    (.differential.consumedAllowances | length) > 0 and
    (
      .differential.consumedAllowances
      | map(.id) | length
    ) == (
      .differential.consumedAllowances
      | map(.id) | unique | length
    ) and
    all(
      .differential.consumedAllowances[];
      (
        .pinnedExpectation.kind == "exact" or
        .pinnedExpectation.kind == "absent"
      ) and
      (
        .iosUseExpectation.kind == "exact" or
        .iosUseExpectation.kind == "absent"
      ) and
      (.reason | length) > 0 and
      (.pinnedSymbol | length) > 0 and
      (.iosUseSymbol | length) > 0
    ) and
    (
      .differential.consumedBaselines | map(.id) | sort
    ) == [
      "external-ios-use-runtime-input",
      "external-pinned-akinterface-input"
    ]
  ' "$CANDIDATE_PATH" >/dev/null; then
  echo \
    "[playcover-external-prepare-differential] ERROR: candidate external attestation is incomplete" \
    >&2
  exit 1
fi

CANDIDATE_SHA256="$(
  /usr/bin/shasum -a 256 "$CANDIDATE_PATH" | /usr/bin/awk '{print $1}'
)"
if ! /bin/ln "$CANDIDATE_PATH" "$ATTESTATION_PATH"; then
  echo \
    "[playcover-external-prepare-differential] ERROR: could not publish evidence without overwrite" \
    >&2
  exit 78
fi
cleanup
trap - EXIT

if [[ "$(/usr/bin/stat -f '%HT:%Lp:%u:%l' "$ATTESTATION_PATH")" \
    != "Regular File:600:$(id -u):1" ]] ||
   [[ "$(
     /usr/bin/shasum -a 256 "$ATTESTATION_PATH" |
       /usr/bin/awk '{print $1}'
   )" != "$CANDIDATE_SHA256" ]]; then
  echo \
    "[playcover-external-prepare-differential] ERROR: published attestation identity changed" \
    >&2
  exit 1
fi

echo "[playcover-external-prepare-differential] PASS"
echo \
  "[playcover-external-prepare-differential] evidence retained: $ATTESTATION_PATH"
