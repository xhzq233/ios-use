#!/bin/bash
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_HOME="${IOS_USE_HOME:-$HOME/.ios-use/test-homes/snapshot}"
mkdir -p "$TEST_HOME"
TEST_HOME="$(cd "$TEST_HOME" && pwd -P)"
TEST_ROOT="$(mktemp -d "$TEST_HOME/snapshot.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
# A Catalyst command-line harness, not a PlayCover App: no account-global
# preparation, signing identity, App slot or PlayChain state is accessed.
xcrun clang -target arm64-apple-ios15.0-macabi -isysroot "$SDK_PATH" \
  -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -I"$ROOT_DIR/playcover-runtime" -framework Foundation \
  "$ROOT_DIR/playcover-runtime/IOSUsePlaySnapshot.m" \
  "$ROOT_DIR/playcover-runtime/tests/SnapshotCancellationHarness.m" \
  -o "$TEST_ROOT/snapshot-harness"
"$TEST_ROOT/snapshot-harness"
