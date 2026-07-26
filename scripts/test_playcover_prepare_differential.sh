#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 0 ]]; then
  echo "Usage: scripts/test_playcover_prepare_differential.sh" >&2
  exit 64
fi

for tool in /usr/bin/codesign /usr/bin/xcrun; do
  if [[ ! -x "$tool" ]]; then
    echo "[playcover-prepare-differential] ERROR: missing $tool" >&2
    exit 1
  fi
done

TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/ios-use-playcover-differential.XXXXXX")"
cleanup() {
  rm -f "$TEST_LOG"
}
trap cleanup EXIT

echo "[playcover-prepare-differential] running pinned Installer headless oracle"
swift test \
  --package-path "$ROOT_DIR/swift-cli" \
  --filter PlayCoverPrepareDifferentialTests 2>&1 | tee "$TEST_LOG"

required_tests=(
  testPinnedHeadlessInstallerOracleAndIOSUsePrepareHaveOnlyRecordedDifferences
  testDifferentialGateRejectsUnrecordedAndStaleAllowances
  testDifferentialGateRejectsSecondarySliceOnlyMutation
  testEmptySliceArrayFallsBackToCoveredLegacySlice
  testOneSidedObjectsRequireExactNonStaleBaselines
)
for test_name in "${required_tests[@]}"; do
  sentinel="Test Case '-[IOSUseCLITests.PlayCoverPrepareDifferentialTests ${test_name}]' passed"
  if ! grep -Fq "$sentinel" "$TEST_LOG"; then
    echo "[playcover-prepare-differential] ERROR: missing passing test sentinel: $test_name" >&2
    exit 1
  fi
done

echo "[playcover-prepare-differential] PASS"
