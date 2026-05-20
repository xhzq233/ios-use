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
mkdir -p \
  "$FAKE_SOURCE/ios-use-skill" \
  "$FAKE_SOURCE/flows" \
  "$FAKE_SOURCE/swift-cli" \
  "$FAKE_SOURCE/scripts" \
  "$FAKE_BIN" \
  "$FAKE_HOME"

printf 'remote skill fixture\n' > "$FAKE_SOURCE/ios-use-skill/SKILL.md"
printf 'name: remote-flow\n' > "$FAKE_SOURCE/flows/example.yaml"
printf '// fake package\n' > "$FAKE_SOURCE/swift-cli/Package.swift"
cat > "$FAKE_SOURCE/scripts/build_swift_cli.sh" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cat > "$ROOT_DIR/ios-use" <<'CLI'
#!/bin/sh
echo 1.0.2
CLI
chmod +x "$ROOT_DIR/ios-use"
SCRIPT
chmod +x "$FAKE_SOURCE/scripts/build_swift_cli.sh"
(cd "$FAKE_SOURCE_PARENT" && tar -czf "$FAKE_TARBALL" ios-use-fake)

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
      printf 'echo 1.0.2\n'
    } | write_output
    chmod +x "$out"
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

run_install() {
  local home="$1"
  shift
  HOME="$home" \
    XDG_BIN_HOME="$home/bin" \
    IOS_USE_GITHUB_REPO="example/ios-use" \
    IOS_USE_VERSION="v1.0.2" \
    IOS_USE_INSTALL_TEST_TARBALL="$FAKE_TARBALL" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$ROOT_DIR/scripts/install.sh" "$@" --print-path
}

BUILD_HOME="$FAKE_HOME/build-from-source"
mkdir -p "$BUILD_HOME"
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

echo "[install-test] install smoke test passed"
