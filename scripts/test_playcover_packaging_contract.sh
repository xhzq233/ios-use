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
    "$FIXTURE_ROOT/ThirdParty/PlayCover" \
    "$FIXTURE_ROOT/ThirdParty/inject" \
    "$FIXTURE_ROOT/ThirdParty/Yams" \
    "$FIXTURE_ROOT/playcover-runtime" \
    "$FIXTURE_ROOT/swift-cli"

  cp "$ROOT_DIR/scripts/audit_playcover_upstreams.sh" "$FIXTURE_ROOT/scripts/"
  cp "$ROOT_DIR/ThirdParty/LICENSES.md" "$FIXTURE_ROOT/ThirdParty/"
  cp "$ROOT_DIR/ThirdParty/PlayCover/Package.swift" \
    "$ROOT_DIR/ThirdParty/PlayCover/Package.resolved" \
    "$ROOT_DIR/ThirdParty/PlayCover/PROVENANCE.md" \
    "$FIXTURE_ROOT/ThirdParty/PlayCover/"
  cp -R "$ROOT_DIR/ThirdParty/PlayCover/PlayCover" \
    "$FIXTURE_ROOT/ThirdParty/PlayCover/"
  cp "$ROOT_DIR/ThirdParty/inject/PROVENANCE.md" \
    "$ROOT_DIR/ThirdParty/inject/Package.swift" \
    "$FIXTURE_ROOT/ThirdParty/inject/"
  cp -R "$ROOT_DIR/ThirdParty/inject/Injection" \
    "$FIXTURE_ROOT/ThirdParty/inject/"
  cp "$ROOT_DIR/ThirdParty/Yams/LICENSE" \
    "$ROOT_DIR/ThirdParty/Yams/PROVENANCE.md" \
    "$FIXTURE_ROOT/ThirdParty/Yams/"
  cp -R "$ROOT_DIR/playcover-runtime/PlayTools" \
    "$FIXTURE_ROOT/playcover-runtime/"
  cp "$ROOT_DIR/playcover-runtime/project.yml" "$FIXTURE_ROOT/playcover-runtime/"
  cp "$ROOT_DIR/swift-cli/Package.resolved" "$FIXTURE_ROOT/swift-cli/"
}

expect_metadata_failure() {
  local description="$1"
  if bash "$FIXTURE_ROOT/scripts/audit_playcover_upstreams.sh" \
      --metadata-only >/dev/null 2>&1; then
    echo "[packaging-contract] ERROR: audit accepted $description" >&2
    exit 1
  fi
}

echo "[packaging-contract] validating the current metadata closure"
bash "$ROOT_DIR/scripts/audit_playcover_upstreams.sh" --metadata-only

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
  's/3036ba9d69cf1fd04d433527bc339dc0dc75433d/0000000000000000000000000000000000000000/' \
  "$FIXTURE_ROOT/ThirdParty/PlayCover/Package.resolved"
rm "$FIXTURE_ROOT/ThirdParty/PlayCover/Package.resolved.bak"
expect_metadata_failure "a Yams resolution that differs from its audited pin"

prepare_fixture
sed -i.bak \
  's/| Yams | `3036ba9d69cf1fd04d433527bc339dc0dc75433d` | MIT/| Yams | `3036ba9d69cf1fd04d433527bc339dc0dc75433d` | Apache-2.0/' \
  "$FIXTURE_ROOT/ThirdParty/LICENSES.md"
rm "$FIXTURE_ROOT/ThirdParty/LICENSES.md.bak"
expect_metadata_failure "a third-party license manifest that differs from provenance"

echo "[packaging-contract] metadata, pin, and expected-file negative cases PASS"
