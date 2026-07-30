#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_DIFFERENTIAL_ATTESTATION_DIR:-}"

if [[ $# -ne 0 ]]; then
  echo "Usage: scripts/test_playcover_prepare_differential.sh" >&2
  exit 64
fi

for tool in \
  /bin/ln \
  /usr/bin/codesign \
  /usr/bin/plutil \
  /usr/bin/stat \
  /usr/bin/xcrun; do
  if [[ ! -x "$tool" ]]; then
    echo "[playcover-prepare-differential] ERROR: missing $tool" >&2
    exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "[playcover-prepare-differential] ERROR: missing jq" >&2
  exit 1
fi

if [[ -z "$EVIDENCE_ROOT" ]]; then
  EVIDENCE_ROOT="$(
    mktemp -d "/tmp/ios-use-playcover-differential-evidence.XXXXXX"
  )"
elif [[ "$EVIDENCE_ROOT" != /* ]]; then
  echo \
    "[playcover-prepare-differential] ERROR: attestation directory must be absolute" \
    >&2
  exit 78
elif [[ ! -d "$EVIDENCE_ROOT" ]]; then
  echo \
    "[playcover-prepare-differential] ERROR: configured attestation directory must already exist" \
    >&2
  exit 78
fi
EVIDENCE_ROOT="$(cd "$EVIDENCE_ROOT" && pwd -P)"
case "$EVIDENCE_ROOT/" in
  "$ROOT_DIR/"*)
    echo \
      "[playcover-prepare-differential] ERROR: attestation directory must be outside the checkout" \
      >&2
    exit 78
    ;;
esac
ATTESTATION_PATH="$EVIDENCE_ROOT/playcover-prepare-differential-hermetic-v1.json"
if [[ -e "$ATTESTATION_PATH" ]]; then
  echo \
    "[playcover-prepare-differential] ERROR: refusing to overwrite $ATTESTATION_PATH" \
    >&2
  exit 78
fi
CANDIDATE_DIR="$(
  mktemp -d \
    "$EVIDENCE_ROOT/.playcover-prepare-differential-candidate.XXXXXX"
)"
CANDIDATE_PATH="$CANDIDATE_DIR/attestation.json"
SCRATCH_PATH="$(
  mktemp -d "/tmp/ios-use-playcover-differential-build.XXXXXX"
)"
case "$SCRATCH_PATH" in
  /tmp/ios-use-playcover-differential-build.*|\
  /private/tmp/ios-use-playcover-differential-build.*) ;;
  *)
    echo \
      "[playcover-prepare-differential] ERROR: unsafe isolated build path" \
      >&2
    exit 1
    ;;
esac

TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/ios-use-playcover-differential.XXXXXX")"
cleanup() {
  rm -f "$CANDIDATE_PATH" "$TEST_LOG"
  /bin/rm -rf -- "$SCRATCH_PATH"
  rmdir "$CANDIDATE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "[playcover-prepare-differential] running pinned Installer headless oracle"
(
  # Keep the published evidence owner-only, but make the reviewed fixture's
  # directory/resource modes deterministic instead of inheriting the caller's
  # umask.
  umask 022
  IOS_USE_PLAYCOVER_DIFFERENTIAL_ATTESTATION_PATH="$CANDIDATE_PATH" \
    swift test \
    --package-path "$ROOT_DIR/swift-cli" \
    --scratch-path "$SCRATCH_PATH" \
    --filter PlayCoverPrepareDifferentialTests
) 2>&1 | tee "$TEST_LOG"

required_tests=(
  testPinnedHeadlessInstallerOracleAndIOSUsePrepareHaveOnlyRecordedDifferences
  testPinnedOracleUsesCanonicalRelativePathsForSymlinkedSourceAncestor
  testDifferentialGateRejectsUnrecordedAndStaleAllowances
  testAppAndInventoryDifferencesRequireExactAllowances
  testAttestationRejectsUnconstrainedNormalization
  testHermeticNormalizationRejectsAliasedOrNestedHomes
  testHermeticNormalizationDoesNotRewriteSiblingPrefixes
  testHermeticNormalizationDoesNotInventPrivateAlias
  testAttestationRejectsPrimitiveCharacterizationLineage
  testAttestationBindsPreparedAppsToTheirManagedHomes
  testAttestationRequiresEverySliceSelectorToBeCovered
  testDifferentialGateRejectsSecondarySliceOnlyMutation
  testEmptySliceArrayFallsBackToCoveredLegacySlice
  testOneSidedObjectsRequireExactNonStaleBaselines
  testVendoredPlayAppSigningAuthorityIsOrderedAndExplicitlyExcluded
)
for test_name in "${required_tests[@]}"; do
  sentinel="Test Case '-[IOSUseCLITests.PlayCoverPrepareDifferentialTests ${test_name}]' passed"
  if ! grep -Fq "$sentinel" "$TEST_LOG"; then
    echo "[playcover-prepare-differential] ERROR: missing passing test sentinel: $test_name" >&2
    exit 1
  fi
done

if [[ ! -s "$CANDIDATE_PATH" ]]; then
  echo \
    "[playcover-prepare-differential] ERROR: hermetic attestation was not written" \
    >&2
  exit 1
fi
if [[ "$(/usr/bin/stat -f '%Lp' "$CANDIDATE_PATH")" != "600" ]]; then
  echo \
    "[playcover-prepare-differential] ERROR: candidate evidence is not owner-only" \
    >&2
  exit 1
fi
if [[ "$(
  /usr/bin/plutil -extract schemaVersion raw -o - "$CANDIDATE_PATH"
)" != "1" ]]; then
  echo \
    "[playcover-prepare-differential] ERROR: evidence has the wrong schema" \
    >&2
  exit 1
fi
if [[ "$(
  /usr/bin/plutil -extract scope raw -o - "$CANDIDATE_PATH"
)" != "hermetic-fixture" ]]; then
  echo \
    "[playcover-prepare-differential] ERROR: evidence has the wrong scope" \
    >&2
  exit 1
fi
if [[ "$(
  /usr/bin/plutil -extract result raw -o - "$CANDIDATE_PATH"
)" != "pass" ]]; then
  echo \
    "[playcover-prepare-differential] ERROR: evidence does not record a pass" \
    >&2
  exit 1
fi
if ! jq -e '
    def sorted_unique: sort | unique;
    def object_union:
      (
        .selectorCoverage.pinnedObjectSelectors
        + .selectorCoverage.iosUseObjectSelectors
      ) | sorted_unique;
    def slice_union:
      (
        .selectorCoverage.pinnedSliceSelectors
        + .selectorCoverage.iosUseSliceSelectors
      ) | sorted_unique;
    def inventory_union:
      (
        .appCoverage.pinnedInventorySelectors
        + .appCoverage.iosUseInventorySelectors
      ) | sorted_unique;
    .schemaVersion == 1 and
    .scope == "hermetic-fixture" and
    .result == "pass" and
    .source.unchanged == true and
    .source.inputContentSHA256 ==
      .source.pinnedHashAfterPrepare and
    .source.inputContentSHA256 ==
      .source.iosUseHashAfterPrepare and
    .source.inputContentSHA256 ==
      .source.recomputedAtAttestationSHA256 and
    .implementation.algorithm ==
      "embedded-source-closure-plus-loaded-xctest-inode-sha256-v2" and
    (.implementation.contentSHA256 |
      test("^[0-9a-f]{64}$")) and
    .implementation.embeddedSourceClosureSHA256 ==
      .implementation.contentSHA256 and
    (.implementation.testExecutableSHA256 |
      test("^[0-9a-f]{64}$")) and
    .implementation.testExecutableSize > 0 and
    .implementation.testExecutableDevice > 0 and
    .implementation.testExecutableInode > 0 and
    .implementation.relativeSourcePaths == ([
      "ThirdParty/PlayCover/Package.resolved",
      "ThirdParty/PlayCover/Package.swift",
      "ThirdParty/PlayCover/PROVENANCE.md",
      "ThirdParty/PlayCover/PlayCover/AppInstaller/Installer.swift",
      "ThirdParty/PlayCover/PlayCover/Headless/HeadlessSupport.swift",
      "ThirdParty/PlayCover/PlayCover/Headless/PlayCoverPrepareDifferential.swift",
      "ThirdParty/PlayCover/PlayCover/Headless/PlayCoverUpstreamEngine.swift",
      "ThirdParty/PlayCover/PlayCover/Model/AppInfo.swift",
      "ThirdParty/PlayCover/PlayCover/Model/BaseApp.swift",
      "ThirdParty/PlayCover/PlayCover/Model/PlayApp.swift",
      "ThirdParty/PlayCover/PlayCover/Model/PlayRules.swift",
      "ThirdParty/PlayCover/PlayCover/PlayCoverError.swift",
      "ThirdParty/PlayCover/PlayCover/Rules/default.yaml",
      "ThirdParty/PlayCover/PlayCover/Utils/Entitlements.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/Extensions/DataExtensions.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/Extensions/FileExtensions.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/Extensions/PlayAppExtensions.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/Extensions/URLExtensions.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/KeyCover.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/Macho.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/PlayTools.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/Shell.swift",
      "ThirdParty/PlayCover/PlayCover/Utils/SystemConfig.swift",
      "ThirdParty/inject/Injection/Injection/BitType.swift",
      "ThirdParty/inject/Injection/Injection/Command.swift",
      "ThirdParty/inject/Injection/Injection/Extension.swift",
      "ThirdParty/inject/Injection/Injection/Inject.swift",
      "ThirdParty/inject/Injection/Injection/Shell.swift",
      "ThirdParty/inject/Package.swift",
      "ThirdParty/inject/PROVENANCE.md",
      "scripts/audit_playcover_upstreams.sh",
      "scripts/test_playcover_external_prepare_differential.sh",
      "scripts/test_playcover_prepare_differential.sh",
      "swift-cli/Package.resolved",
      "swift-cli/Package.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverCodeSignatureInspector.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverGlobalReferenceStore.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverLaunchCrashCut.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverManagedAppService.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverModels.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverService.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverSigningCertificateBuilder.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverSigningIdentityService.swift",
      "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverPreparedArtifact.swift",
      "swift-cli/Sources/IOSUseCLI/Support/IOSUsePaths.swift",
      "swift-cli/Tests/IOSUseCLITests/PlayCover/PlayCoverExternalPrepareDifferentialTests.swift",
      "swift-cli/Tests/IOSUseCLITests/PlayCover/PlayCoverPrepareDifferentialTests.swift",
      "swift-cli/Tests/IOSUseCLITests/PlayCover/PlayCoverSigningEvidenceTestSupport.swift"
    ] | sort) and
    .normalization.mode ==
      "hermetic-fixture-managed-paths-v1" and
    .pinnedOutput.preparationLineage ==
      "pinned-headless-installer-oracle" and
    .iosUseOutput.preparationLineage ==
      "ios-use-service-and-upstream-engine" and
    .appCoverage.checkedFieldFamilies == [
      "info-plist",
      "bundle-identity",
      "executable-identity",
      "root-signature",
      "provisioning",
      "inventory"
    ] and
    (
      .selectorCoverage.objects | map(.selector)
    ) == object_union and
    (
      .selectorCoverage.matchedSlices | map(.selector)
    ) == slice_union and
    (
      .appCoverage.inventoryEntries | map(.selector)
    ) == inventory_union and
    (.selectorCoverage.objects | length) > 0 and
    (.selectorCoverage.matchedSlices | length) > 0 and
    (.appCoverage.inventoryEntries | length) > 0 and
    all(
      .selectorCoverage.matchedSlices[];
      .checkedFieldFamilies == [
        "container",
        "slice-layout",
        "immutable-content",
        "mach-header",
        "platform",
        "encryption",
        "load-commands",
        "rpaths",
        "dependencies",
        "signature-metadata",
        "signature-superblob",
        "signature-code-directory",
        "xml-entitlements",
        "der-entitlements"
      ]
    ) and
    all(
      .appCoverage.inventoryEntries[];
      .checkedFieldFamilies == [
        "presence",
        "kind",
        "size",
        "permissions",
        "content",
        "symbolic-link-destination",
        "code-object-kind"
      ]
    ) and
    (.consumedAllowances | length) > 0 and
    (
      .consumedBaselines | map(.id) | sort
    ) == [
      "ios-use-runtime-input",
      "pinned-akinterface-input"
    ]
  ' "$CANDIDATE_PATH" >/dev/null; then
  echo \
    "[playcover-prepare-differential] ERROR: candidate evidence is incomplete" \
    >&2
  exit 1
fi

if ! /bin/ln "$CANDIDATE_PATH" "$ATTESTATION_PATH"; then
  echo \
    "[playcover-prepare-differential] ERROR: could not publish evidence without overwrite" \
    >&2
  exit 78
fi

{
  echo \
    "[playcover-prepare-differential] PASS (hermetic fixture attestation only)"
  echo \
    "[playcover-prepare-differential] evidence retained: $ATTESTATION_PATH"
  echo \
    "[playcover-prepare-differential] real-App differential attestation remains unconfigured; IOS_USE_PLAYCOVER_LIVE_SCENARIO is not consumed by this gate"
} || true
cleanup || true
trap - EXIT
exit 0
