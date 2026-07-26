#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[install-test] Skipping install smoke test on non-macOS host"
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-install-test.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

FAKE_SOURCE_PARENT="$TMP_ROOT/source"
FAKE_SOURCE="$FAKE_SOURCE_PARENT/ios-use-fake"
FAKE_TARBALL="$TMP_ROOT/source.tar.gz"
FAKE_BIN="$TMP_ROOT/fake-bin"
FAKE_HOME="$TMP_ROOT/home"
FAKE_RUNTIME_DIR="$TMP_ROOT/runtime/IOSUsePlayRuntime.framework"
FAKE_RUNTIME_ARCHIVE="$TMP_ROOT/ios-use-playcover-runtime.tar.gz"
FAKE_CHECKSUMS="$TMP_ROOT/SHA256SUMS"
mkdir -p \
  "$FAKE_SOURCE/ios-use-skill" \
  "$FAKE_SOURCE/swift-cli" \
  "$FAKE_SOURCE/scripts" \
  "$FAKE_RUNTIME_DIR" \
  "$FAKE_BIN" \
  "$FAKE_HOME"

printf 'remote skill fixture\n' > "$FAKE_SOURCE/ios-use-skill/SKILL.md"
printf '// fake package\n' > "$FAKE_SOURCE/swift-cli/Package.swift"
cat > "$FAKE_SOURCE/scripts/build_swift_cli.sh" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cat > "$ROOT_DIR/ios-use" <<'CLI'
#!/bin/sh
echo 1.0.3
CLI
chmod +x "$ROOT_DIR/ios-use"
mkdir -p "$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
cat > "$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework/IOSUsePlayRuntime" <<'RUNTIME'
#!/bin/sh
echo runtime
RUNTIME
chmod +x "$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework/IOSUsePlayRuntime"
printf '%s\n' '<plist version="1.0"><dict/></plist>' > "$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework/Info.plist"
SCRIPT
chmod +x "$FAKE_SOURCE/scripts/build_swift_cli.sh"
(cd "$FAKE_SOURCE_PARENT" && tar -czf "$FAKE_TARBALL" ios-use-fake)

printf '#!/bin/sh\necho runtime\n' > "$FAKE_RUNTIME_DIR/IOSUsePlayRuntime"
chmod +x "$FAKE_RUNTIME_DIR/IOSUsePlayRuntime"
printf '%s\n' '<plist version="1.0"><dict/></plist>' > "$FAKE_RUNTIME_DIR/Info.plist"
(cd "$(dirname "$FAKE_RUNTIME_DIR")" && tar -czf "$FAKE_RUNTIME_ARCHIVE" IOSUsePlayRuntime.framework)
{
  printf '#!/bin/sh\necho 1.0.3\n' | shasum -a 256 | awk '{print $1 "  ios-use-darwin-arm64"}'
  printf 'remote-driver\n' | shasum -a 256 | awk '{print $1 "  driver.ipa"}'
  printf 'remote-driver-sim\n' | shasum -a 256 | awk '{print $1 "  driver-sim.ipa"}'
  shasum -a 256 "$FAKE_RUNTIME_ARCHIVE" | awk '{print $1 "  ios-use-playcover-runtime.tar.gz"}'
} > "$FAKE_CHECKSUMS"

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

write_output() {
  if [[ -n "$out" ]]; then
    cat > "$out"
  else
    cat
  fi
}

case "$url" in
  *codeload.github.com*)
    if [[ -n "$out" ]]; then
      cp "$IOS_USE_INSTALL_TEST_TARBALL" "$out"
    else
      cat "$IOS_USE_INSTALL_TEST_TARBALL"
    fi
    ;;
  *ios-use-darwin-arm64)
    {
      printf '#!/bin/sh\n'
      printf 'echo 1.0.3\n'
    } | write_output
    chmod +x "$out"
    ;;
  *ios-use-playcover-runtime.tar.gz)
    cat "$IOS_USE_INSTALL_TEST_RUNTIME_ARCHIVE" | write_output
    ;;
  *SHA256SUMS)
    cat "$IOS_USE_INSTALL_TEST_CHECKSUMS" | write_output
    ;;
  *driver.ipa)
    printf 'remote-driver\n' | write_output
    ;;
  *driver-sim.ipa)
    printf 'remote-driver-sim\n' | write_output
    ;;
  *altsign-cli)
    {
      printf '#!/bin/sh\n'
      printf 'echo altsign\n'
    } | write_output
    chmod +x "$out"
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
SCRIPT
chmod +x "$FAKE_BIN/curl"

cat > "$FAKE_BIN/codesign" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "$FAKE_BIN/codesign"

cat > "$FAKE_BIN/xcodegen" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "$FAKE_BIN/xcodegen"

cat > "$FAKE_BIN/swift" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "$FAKE_BIN/swift"

cat > "$FAKE_BIN/xcrun" <<'SCRIPT'
#!/bin/sh
if [ "$1" = "--sdk" ] &&
   [ "$2" = "iphoneos" ] &&
   [ "$3" = "--show-sdk-path" ]; then
  printf '/fake/iPhoneOS.sdk\n'
  exit 0
fi
exit 1
SCRIPT
chmod +x "$FAKE_BIN/xcrun"

cat > "$FAKE_BIN/uname" <<'SCRIPT'
#!/bin/sh
case "${1:-}" in
  -s) printf 'Darwin\n' ;;
  -m) printf '%s\n' "${IOS_USE_INSTALL_TEST_ARCH:-arm64}" ;;
  *) printf 'Darwin\n' ;;
esac
SCRIPT
chmod +x "$FAKE_BIN/uname"

run_install() {
  local home="$1"
  shift
  HOME="$home" \
    XDG_BIN_HOME="$home/bin" \
    IOS_USE_GITHUB_REPO="example/ios-use" \
    IOS_USE_VERSION="v1.0.3" \
    IOS_USE_INSTALL_TEST_TARBALL="$FAKE_TARBALL" \
    IOS_USE_INSTALL_TEST_RUNTIME_ARCHIVE="$FAKE_RUNTIME_ARCHIVE" \
    IOS_USE_INSTALL_TEST_CHECKSUMS="${IOS_USE_INSTALL_TEST_CHECKSUM_OVERRIDE:-$FAKE_CHECKSUMS}" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$ROOT_DIR/scripts/install.sh" "$@" --print-path
}

run_install_verbose() {
  local home="$1"
  shift
  HOME="$home" \
    XDG_BIN_HOME="$home/bin" \
    IOS_USE_GITHUB_REPO="example/ios-use" \
    IOS_USE_VERSION="v1.0.3" \
    IOS_USE_INSTALL_TEST_TARBALL="$FAKE_TARBALL" \
    IOS_USE_INSTALL_TEST_RUNTIME_ARCHIVE="$FAKE_RUNTIME_ARCHIVE" \
    IOS_USE_INSTALL_TEST_CHECKSUMS="${IOS_USE_INSTALL_TEST_CHECKSUM_OVERRIDE:-$FAKE_CHECKSUMS}" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$ROOT_DIR/scripts/install.sh" "$@"
}

BUILD_HOME="$FAKE_HOME/build-from-source"
mkdir -p "$BUILD_HOME"
mkdir -p "$BUILD_HOME/.ios-use/flows"
printf 'legacy recipe\n' > "$BUILD_HOME/.ios-use/flows/proxy_configca.yaml"
printf 'legacy recipe\n' > "$BUILD_HOME/.ios-use/flows/subflow_wait_and_find.yaml"
printf 'custom recipe\n' > "$BUILD_HOME/.ios-use/flows/my-local-flow.yaml"
BUILD_PATH="$(run_install "$BUILD_HOME" --build-from-source | tail -n 1)"
if [[ "$BUILD_PATH" != "$BUILD_HOME/bin/ios-use" || ! -x "$BUILD_PATH" ]]; then
  echo "[install-test] ERROR: build-from-source install did not create expected binary" >&2
  exit 1
fi
if ! grep -q 'remote skill fixture' "$BUILD_HOME/.ios-use/skill/SKILL.md"; then
  echo "[install-test] ERROR: install did not use bootstrapped remote skill" >&2
  exit 1
fi
if ! grep -q 'remote-driver' "$BUILD_HOME/.ios-use/driver.ipa"; then
  echo "[install-test] ERROR: install did not download driver.ipa" >&2
  exit 1
fi
if ! grep -q 'remote-driver-sim' "$BUILD_HOME/.ios-use/driver-sim.ipa"; then
  echo "[install-test] ERROR: install did not download driver-sim.ipa" >&2
  exit 1
fi
if [[ ! -x "$BUILD_HOME/.ios-use/altsign-cli/altsign-cli" ]]; then
  echo "[install-test] ERROR: install did not download altsign-cli" >&2
  exit 1
fi
if [[ ! -x "$BUILD_HOME/share/ios-use/playcover/IOSUsePlayRuntime.framework/IOSUsePlayRuntime" ]]; then
  echo "[install-test] ERROR: build-from-source install did not install the PlayCover runtime under its prefix share layout" >&2
  exit 1
fi
if [[ -e "$BUILD_HOME/.ios-use/playcover/IOSUsePlayRuntime.framework" ]]; then
  echo "[install-test] ERROR: build-from-source install left the Runtime in mutable IOS_USE_HOME state" >&2
  exit 1
fi
if [[ -e "$BUILD_HOME/.ios-use/flows/proxy_configca.yaml" ]]; then
  echo "[install-test] ERROR: install kept a bundled legacy Flow recipe" >&2
  exit 1
fi
if [[ -e "$BUILD_HOME/.ios-use/flows/subflow_wait_and_find.yaml" ]]; then
  echo "[install-test] ERROR: install kept an old bundled Flow recipe" >&2
  exit 1
fi
if [[ ! -f "$BUILD_HOME/.ios-use/flows/my-local-flow.yaml" ]]; then
  echo "[install-test] ERROR: install removed a user-authored Flow file" >&2
  exit 1
fi

DOWNLOAD_HOME="$FAKE_HOME/download"
mkdir -p "$DOWNLOAD_HOME"
DOWNLOAD_PATH="$(run_install "$DOWNLOAD_HOME" | tail -n 1)"
if [[ "$DOWNLOAD_PATH" != "$DOWNLOAD_HOME/bin/ios-use" || ! -x "$DOWNLOAD_PATH" ]]; then
  echo "[install-test] ERROR: release download install did not create expected binary" >&2
  exit 1
fi
if ! grep -q 'remote skill fixture' "$DOWNLOAD_HOME/.ios-use/skill/SKILL.md"; then
  echo "[install-test] ERROR: release download install did not use bootstrapped remote skill" >&2
  exit 1
fi
if [[ ! -x "$DOWNLOAD_HOME/share/ios-use/playcover/IOSUsePlayRuntime.framework/IOSUsePlayRuntime" ]]; then
  echo "[install-test] ERROR: release install did not install the prebuilt PlayCover Runtime" >&2
  exit 1
fi
if [[ -e "$DOWNLOAD_HOME/.ios-use/playcover/IOSUsePlayRuntime.framework" ]]; then
  echo "[install-test] ERROR: release install put the Runtime in mutable IOS_USE_HOME state" >&2
  exit 1
fi

VERBOSE_HOME="$FAKE_HOME/verbose"
mkdir -p "$VERBOSE_HOME"
VERBOSE_OUTPUT="$(run_install_verbose "$VERBOSE_HOME")"
if ! grep -q 'ios-use start <udid>' <<<"$VERBOSE_OUTPUT"; then
  echo "[install-test] ERROR: install next steps do not include ios-use start" >&2
  exit 1
fi
if grep -qi 'auto-creates session\|No session start needed' <<<"$VERBOSE_OUTPUT"; then
  echo "[install-test] ERROR: install next steps still mention old auto session semantics" >&2
  exit 1
fi

BAD_CHECKSUMS="$TMP_ROOT/SHA256SUMS.bad"
sed '1s/^[0-9a-f]*/0000000000000000000000000000000000000000000000000000000000000000/' \
  "$FAKE_CHECKSUMS" > "$BAD_CHECKSUMS"
BAD_CHECKSUM_HOME="$FAKE_HOME/bad-checksum"
mkdir -p "$BAD_CHECKSUM_HOME"
set +e
BAD_CHECKSUM_OUTPUT="$(
  IOS_USE_INSTALL_TEST_CHECKSUM_OVERRIDE="$BAD_CHECKSUMS" \
    run_install "$BAD_CHECKSUM_HOME" 2>&1
)"
BAD_CHECKSUM_STATUS=$?
set -e
if [[ "$BAD_CHECKSUM_STATUS" -eq 0 ]] ||
   ! grep -q 'Checksum mismatch for ios-use-darwin-arm64' <<<"$BAD_CHECKSUM_OUTPUT"; then
  echo "[install-test] ERROR: release install did not fail a bad CLI checksum" >&2
  exit 1
fi

INTEL_HOME="$FAKE_HOME/intel"
mkdir -p "$INTEL_HOME"
set +e
INTEL_OUTPUT="$(
  IOS_USE_INSTALL_TEST_ARCH=x86_64 \
    run_install "$INTEL_HOME" 2>&1
)"
INTEL_STATUS=$?
set -e
if [[ "$INTEL_STATUS" -eq 0 ]] ||
   ! grep -q 'Intel macOS is unsupported' <<<"$INTEL_OUTPUT"; then
  echo "[install-test] ERROR: installer did not reject unsupported Intel macOS" >&2
  exit 1
fi

echo "[install-test] install smoke test passed"
