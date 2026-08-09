#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-packaging-contract.XXXXXX")"
FIXTURE_ROOT="$TEST_TEMP/repo"

cleanup() {
  rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

prepare_fixture() {
  rm -rf "$FIXTURE_ROOT"
  mkdir -p \
    "$FIXTURE_ROOT/scripts" \
    "$FIXTURE_ROOT/ThirdParty/Frida" \
    "$FIXTURE_ROOT/ThirdParty/PlayCover" \
    "$FIXTURE_ROOT/ThirdParty/inject" \
    "$FIXTURE_ROOT/playcover-runtime" \
    "$FIXTURE_ROOT/swift-cli/Sources/IOSUseCLI/Backends/PlayCover"

  cp \
    "$ROOT_DIR/scripts/audit_playcover_upstreams.sh" \
    "$ROOT_DIR/scripts/build_playcover_frida_engine.sh" \
    "$ROOT_DIR/scripts/build_playcover_frida_gum_catalyst.sh" \
    "$FIXTURE_ROOT/scripts/"
  cp "$ROOT_DIR/scripts/frida_distribution.py" "$FIXTURE_ROOT/scripts/"
  cp "$ROOT_DIR/ThirdParty/LICENSES.md" "$FIXTURE_ROOT/ThirdParty/"
  cp "$ROOT_DIR/ThirdParty/Frida/PROVENANCE.md" \
    "$FIXTURE_ROOT/ThirdParty/Frida/"
  cp "$ROOT_DIR/ThirdParty/PlayCover/Package.swift" \
    "$ROOT_DIR/ThirdParty/PlayCover/PROVENANCE.md" \
    "$FIXTURE_ROOT/ThirdParty/PlayCover/"
  cp -R "$ROOT_DIR/ThirdParty/PlayCover/PlayCover" \
    "$FIXTURE_ROOT/ThirdParty/PlayCover/"
  cp "$ROOT_DIR/ThirdParty/inject/PROVENANCE.md" \
    "$ROOT_DIR/ThirdParty/inject/Package.swift" \
    "$FIXTURE_ROOT/ThirdParty/inject/"
  cp -R "$ROOT_DIR/ThirdParty/inject/Injection" \
    "$FIXTURE_ROOT/ThirdParty/inject/"
  cp -R "$ROOT_DIR/playcover-runtime/PlayTools" \
    "$FIXTURE_ROOT/playcover-runtime/"
  cp "$ROOT_DIR/playcover-runtime/project.yml" "$FIXTURE_ROOT/playcover-runtime/"
  cp \
    "$ROOT_DIR/swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverFridaEngineService.swift" \
    "$FIXTURE_ROOT/swift-cli/Sources/IOSUseCLI/Backends/PlayCover/"
}

expect_metadata_failure() {
  local description="$1"
  if bash "$FIXTURE_ROOT/scripts/audit_playcover_upstreams.sh" \
      --metadata-only >/dev/null 2>&1; then
    echo "[packaging-contract] ERROR: audit accepted $description" >&2
    exit 1
  fi
}

expect_frida_metadata_failure() {
  local description="$1"
  if python3 "$FIXTURE_ROOT/scripts/frida_distribution.py" \
      validate-metadata \
      --repository-root "$FIXTURE_ROOT" >/dev/null 2>&1; then
    echo "[packaging-contract] ERROR: Frida audit accepted $description" >&2
    exit 1
  fi
}

echo "[packaging-contract] validating the current metadata closure"
bash "$ROOT_DIR/scripts/audit_playcover_upstreams.sh" --metadata-only
python3 "$ROOT_DIR/scripts/frida_distribution.py" validate-metadata \
  --repository-root "$ROOT_DIR"

prepare_fixture
rm "$FIXTURE_ROOT/ThirdParty/PlayCover/PlayCover/Utils/Macho.swift"
expect_metadata_failure "a missing expected vendored source"

prepare_fixture
sed -i.bak \
  's/7190cc9ce57c8dee0e222918468f2579acc95e1b/0000000000000000000000000000000000000000/' \
  "$FIXTURE_ROOT/ThirdParty/PlayCover/PROVENANCE.md"
rm "$FIXTURE_ROOT/ThirdParty/PlayCover/PROVENANCE.md.bak"
expect_metadata_failure "a provenance pin that differs from the script pin"

prepare_fixture
sed -i.bak \
  's/| PlayCover | `7190cc9ce57c8dee0e222918468f2579acc95e1b` | GPL-3.0/| PlayCover | `7190cc9ce57c8dee0e222918468f2579acc95e1b` | Apache-2.0/' \
  "$FIXTURE_ROOT/ThirdParty/LICENSES.md"
rm "$FIXTURE_ROOT/ThirdParty/LICENSES.md.bak"
expect_metadata_failure "a third-party license manifest that differs from provenance"

prepare_fixture
sed -i.bak \
  's/12de2e4904b63405052508c891b215d056962c18/0000000000000000000000000000000000000000/' \
  "$FIXTURE_ROOT/ThirdParty/Frida/PROVENANCE.md"
rm "$FIXTURE_ROOT/ThirdParty/Frida/PROVENANCE.md.bak"
expect_frida_metadata_failure "a Frida static-closure pin that differs from the reviewed table"

echo "[packaging-contract] metadata, pin, and expected-file negative cases PASS"
