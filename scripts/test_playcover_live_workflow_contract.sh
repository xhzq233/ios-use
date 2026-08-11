#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIVE_WORKFLOW="$ROOT_DIR/.github/workflows/playcover-live.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
BACKEND_GATE="$ROOT_DIR/scripts/test_playcover_backend.sh"

fail() {
  echo "[playcover-live-workflow-contract] ERROR: $*" >&2
  exit 1
}

require_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local description="$4"
  local observed
  observed="$(grep -Ec "$pattern" "$file" || true)"
  [[ "$observed" == "$expected" ]] ||
    fail "$description: expected $expected, observed $observed"
}

require_fixed() {
  local text="$1"
  local file="$2"
  local description="$3"
  grep -Fq "$text" "$file" || fail "$description"
}

require_absent() {
  local text="$1"
  local file="$2"
  local description="$3"
  if grep -Fq "$text" "$file"; then
    fail "$description"
  fi
}

for file in "$LIVE_WORKFLOW" "$RELEASE_WORKFLOW" "$BACKEND_GATE"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "missing tracked input: $file"
done

# Stateful PlayCover jobs are opt-in and run only on the provisioned host.
require_fixed "workflow_dispatch:" "$LIVE_WORKFLOW" \
  "PlayCover integration must be manually dispatched"
require_absent "pull_request:" "$LIVE_WORKFLOW" \
  "PlayCover integration must not run for pull requests"
require_absent "push:" "$LIVE_WORKFLOW" \
  "PlayCover integration must not run for pushes"
require_count 2 \
  'runs-on: \[self-hosted, macOS, arm64, playcover-live\]' \
  "$LIVE_WORKFLOW" \
  "both PlayCover jobs must use the dedicated runner"

for variable in \
  IOS_USE_PLAYCOVER_DISPOSABLE_ACCOUNT_ACK \
  IOS_USE_PLAYCOVER_EXPECTED_ACCOUNT_HOME; do
  require_count 2 \
    "$variable:.*secrets\.$variable" \
    "$LIVE_WORKFLOW" \
    "$variable must be secret-bound in both jobs"
  require_absent "vars.$variable" "$LIVE_WORKFLOW" \
    "$variable must not use a repository variable"
  require_absent "$variable" "$RELEASE_WORKFLOW" \
    "release must not read disposable-account secrets"
done

# The aggregate owns exactly the two core live behavior gates.
require_count 1 \
  'test_playcover_pending_launch_crash_live\.sh.*--live' \
  "$BACKEND_GATE" \
  "launch-recovery gate must be in the aggregate"
require_count 1 \
  'test_playcover_runtime_stress_live\.sh' \
  "$BACKEND_GATE" \
  "Runtime stress gate must be in the aggregate"
require_absent \
  'bash "$ROOT_DIR/scripts/test_playcover_fixture_live.sh"' \
  "$BACKEND_GATE" \
  "optional fixture diagnostics must stay outside the core aggregate"
require_absent \
  'bash "$ROOT_DIR/scripts/test_playcover_external_app_live.sh"' \
  "$BACKEND_GATE" \
  "optional external-App diagnostics must stay outside the core aggregate"

require_fixed "bash scripts/test_playcover_backend.sh --non-live" \
  "$LIVE_WORKFLOW" \
  "manual workflow must expose the non-live aggregate"
require_fixed "bash scripts/test_playcover_backend.sh --live" \
  "$LIVE_WORKFLOW" \
  "manual workflow must expose the live aggregate"
require_fixed "set -o pipefail" "$LIVE_WORKFLOW" \
  "live logging must preserve aggregate failure"

# Only one small runner-temporary log is uploaded; checkout state stays private.
require_count 1 'uses: actions/upload-artifact@v4' "$LIVE_WORKFLOW" \
  "manual workflow must have one artifact upload"
require_fixed \
  'path: ${{ runner.temp }}/ios-use-playcover-live-${{ github.run_id }}/run.log' \
  "$LIVE_WORKFLOW" \
  "live artifact must be the runner-temporary run.log"
require_absent '${{ github.workspace }}' "$LIVE_WORKFLOW" \
  "live artifacts must not come from the checkout"

# Release remains hosted, non-live, and isolated from account-global state.
require_fixed "runs-on: macos-26" "$RELEASE_WORKFLOW" \
  "release must use a clean hosted runner"
require_fixed \
  "bash scripts/test_playcover_installed_layout.sh --release-dir release --verify-only" \
  "$RELEASE_WORKFLOW" \
  "release must use isolated installed-layout verification"

echo "[playcover-live-workflow-contract] manual-only live and isolated release contracts PASS"
