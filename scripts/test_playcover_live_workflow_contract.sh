#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
BACKEND_GATE="$ROOT_DIR/scripts/test_playcover_backend.sh"
FIXTURE_DIAGNOSTIC="$ROOT_DIR/scripts/test_playcover_fixture_live.sh"
EXTERNAL_DIAGNOSTIC="$ROOT_DIR/scripts/test_playcover_external_app_live.sh"
TEST_TEMP="$(mktemp -d "/tmp/ios-use-live-workflow-contract.XXXXXX")"

cleanup() {
  case "$TEST_TEMP" in
    /tmp/ios-use-live-workflow-contract.*|\
    /private/tmp/ios-use-live-workflow-contract.*)
      rm -rf -- "$TEST_TEMP"
      ;;
  esac
}
trap cleanup EXIT

fail_contract() {
  echo "[playcover-live-workflow-contract] ERROR: $*" >&2
  return 1
}

count_fixed_line() {
  local file="$1"
  local expected="$2"
  grep -Fxc "$expected" "$file" 2>/dev/null || true
}

count_pattern() {
  local file="$1"
  local pattern="$2"
  grep -Ec "$pattern" "$file" 2>/dev/null || true
}

require_line_count() {
  local file="$1"
  local expected="$2"
  local count="$3"
  local description="$4"
  if [[ "$(count_fixed_line "$file" "$expected")" != "$count" ]]; then
    fail_contract "$description must appear exactly $count time(s)"
  fi
}

require_exact_line() {
  require_line_count "$1" "$2" 1 "$3"
}

require_absent_fixed() {
  local file="$1"
  local forbidden="$2"
  local description="$3"
  if grep -Fq "$forbidden" "$file"; then
    fail_contract "$description must be absent"
  fi
}

validate_workflow() {
  local file="$1"

  require_line_count \
    "$file" \
    '    runs-on: [self-hosted, macOS, arm64, playcover-live]' \
    2 \
    "the provisioned PlayCover runner binding for both PlayCover jobs" ||
    return 1
  require_exact_line \
    "$file" \
    '        description: "Run the core pending-launch and Runtime crash/stress gate on its dedicated self-hosted runner."' \
    "the core live workflow-dispatch description" ||
    return 1
  require_exact_line \
    "$file" \
    '      IOS_USE_PLAYCOVER_LIVE_RUN_DIR: ${{ runner.temp }}/ios-use-playcover-live-run-${{ github.run_id }}' \
    "the runner-temporary core live log directory" ||
    return 1
  if [[ "$(
    count_pattern \
      "$file" \
      '^[[:space:]]*IOS_USE_PLAYCOVER_LIVE_[A-Z_]+:'
  )" != "1" ]]; then
    fail_contract "the core live workflow must define only its run-log directory"
    return 1
  fi

  require_exact_line \
    "$file" \
    '          mkdir -p "$IOS_USE_PLAYCOVER_LIVE_RUN_DIR"' \
    "core live run-log directory creation" ||
    return 1
  require_exact_line \
    "$file" \
    '          bash scripts/test_playcover_backend.sh --live 2>&1 |' \
    "the core live aggregate invocation" ||
    return 1
  require_exact_line \
    "$file" \
    '          set -o pipefail' \
    "the core live aggregate pipeline failure propagation" ||
    return 1
  require_exact_line \
    "$file" \
    '            tee "$IOS_USE_PLAYCOVER_LIVE_RUN_DIR/run.log"' \
    "the pipefail-protected core live run log" ||
    return 1
  require_exact_line \
    "$file" \
    "    if: \${{ github.event_name == 'workflow_dispatch' && inputs.run_playcover_live }}" \
    "the explicit-dispatch-only live job condition" ||
    return 1
  require_exact_line \
    "$file" \
    '        if: ${{ always() }}' \
    "the always-attempted core live log upload" ||
    return 1
  require_exact_line \
    "$file" \
    '          path: ${{ env.IOS_USE_PLAYCOVER_LIVE_RUN_DIR }}/run.log' \
    "the exact core live run-log artifact path" ||
    return 1
  require_exact_line \
    "$file" \
    "          if-no-files-found: error" \
    "the required core live run-log artifact" ||
    return 1
  if [[ "$(count_pattern "$file" 'run\.log')" != "2" ]]; then
    fail_contract "run.log must have exactly one writer and one artifact path"
    return 1
  fi

  require_absent_fixed \
    "$file" \
    "live_evidence_id" \
    "the removed operator evidence input" ||
    return 1
  require_absent_fixed \
    "$file" \
    "IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR" \
    "the removed private attestation directory" ||
    return 1
  require_absent_fixed \
    "$file" \
    "IOS_USE_PLAYCOVER_PRIVATE_EVIDENCE_DIR" \
    "the removed private external-App evidence directory" ||
    return 1
  require_absent_fixed \
    "$file" \
    "external-app-live-v2.json" \
    "the removed external-App attestation requirement" ||
    return 1
  require_absent_fixed \
    "$file" \
    "run-metadata.txt" \
    "the removed operator evidence metadata" ||
    return 1
}

validate_backend_gate() {
  local file="$1"
  local pending_line
  local stress_line

  require_exact_line \
    "$file" \
    '  bash "$ROOT_DIR/scripts/test_playcover_pending_launch_crash_live.sh" --live' \
    "the pending-launch same-boot crash gate" ||
    return 1
  require_exact_line \
    "$file" \
    '  bash "$ROOT_DIR/scripts/test_playcover_runtime_stress_live.sh"' \
    "the isolated Runtime protocol/crash stress gate" ||
    return 1
  if [[ "$(
    count_pattern \
      "$file" \
      '^[[:space:]]*bash "\$ROOT_DIR/scripts/test_playcover_.*_live\.sh"'
  )" != "2" ]]; then
    fail_contract "the core live aggregate must invoke exactly two live scripts"
    return 1
  fi

  require_absent_fixed \
    "$file" \
    'bash "$ROOT_DIR/scripts/test_playcover_fixture_live.sh"' \
    "the optional fixture display diagnostic invocation" ||
    return 1
  require_absent_fixed \
    "$file" \
    'bash "$ROOT_DIR/scripts/test_playcover_external_app_live.sh"' \
    "the optional external-App display diagnostic invocation" ||
    return 1
  require_absent_fixed \
    "$file" \
    "suitable for hosted CI" \
    "the invalid unprovisioned-hosted-CI claim" ||
    return 1
  if ! grep -Fq "initialized stable host signer" "$file" ||
      ! grep -Fq "launch-capable GUI session" "$file"; then
    fail_contract \
      "the non-live integration-host signer and GUI prerequisites are missing"
    return 1
  fi

  pending_line="$(
    grep -nF \
      'bash "$ROOT_DIR/scripts/test_playcover_pending_launch_crash_live.sh" --live' \
      "$file" |
      cut -d: -f1
  )"
  stress_line="$(
    grep -nF \
      'bash "$ROOT_DIR/scripts/test_playcover_runtime_stress_live.sh"' \
      "$file" |
      cut -d: -f1
  )"
  if [[ -z "$pending_line" || -z "$stress_line" ]] ||
      ((pending_line >= stress_line)); then
    fail_contract \
      "the pending-launch gate must run before Runtime protocol/crash stress"
    return 1
  fi
}

expect_workflow_rejected() {
  local file="$1"
  local description="$2"
  if validate_workflow "$file" >/dev/null 2>&1; then
    echo \
      "[playcover-live-workflow-contract] ERROR: accepted $description" \
      >&2
    exit 1
  fi
}

expect_backend_rejected() {
  local file="$1"
  local description="$2"
  if validate_backend_gate "$file" >/dev/null 2>&1; then
    echo \
      "[playcover-live-workflow-contract] ERROR: accepted $description" \
      >&2
    exit 1
  fi
}

validate_workflow "$WORKFLOW"
validate_backend_gate "$BACKEND_GATE"
for optional_diagnostic in \
  "$FIXTURE_DIAGNOSTIC" \
  "$EXTERNAL_DIAGNOSTIC"; do
  if [[ ! -f "$optional_diagnostic" ]]; then
    fail_contract \
      "optional additive diagnostic is missing: $optional_diagnostic"
    exit 1
  fi
done

hosted_non_live="$TEST_TEMP/hosted-non-live.yml"
sed \
  's/runs-on: \[self-hosted, macOS, arm64, playcover-live\]/runs-on: macos-26/g' \
  "$WORKFLOW" >"$hosted_non_live"
expect_workflow_rejected \
  "$hosted_non_live" \
  "PlayCover jobs on an unprovisioned hosted runner"

run_data_in_checkout="$TEST_TEMP/run-data-in-checkout.yml"
sed \
  's#${{ runner.temp }}/ios-use-playcover-live-run-${{ github.run_id }}#${{ github.workspace }}/playcover-live-run#' \
  "$WORKFLOW" >"$run_data_in_checkout"
expect_workflow_rejected \
  "$run_data_in_checkout" \
  "a core live run log below github.workspace"

directory_upload="$TEST_TEMP/directory-upload.yml"
sed \
  's#path: ${{ env.IOS_USE_PLAYCOVER_LIVE_RUN_DIR }}/run.log#path: ${{ env.IOS_USE_PLAYCOVER_LIVE_RUN_DIR }}/#' \
  "$WORKFLOW" >"$directory_upload"
expect_workflow_rejected \
  "$directory_upload" \
  "an entire live run directory upload"

lost_pipefail="$TEST_TEMP/lost-pipefail.yml"
sed '/^[[:space:]]*set -o pipefail$/d' \
  "$WORKFLOW" >"$lost_pipefail"
expect_workflow_rejected \
  "$lost_pipefail" \
  "a live run-log pipeline without pipefail"

private_evidence_input="$TEST_TEMP/private-evidence-input.yml"
sed \
  '/run_playcover_live:/a\
      live_evidence_id:' \
  "$WORKFLOW" >"$private_evidence_input"
expect_workflow_rejected \
  "$private_evidence_input" \
  "a restored private evidence input"

external_attestation="$TEST_TEMP/external-attestation.yml"
sed \
  '/path: .*run.log/a\
          # external-app-live-v2.json' \
  "$WORKFLOW" >"$external_attestation"
expect_workflow_rejected \
  "$external_attestation" \
  "a restored external-App attestation dependency"

missing_stress_gate="$TEST_TEMP/missing-stress-gate.sh"
sed \
  's|bash "$ROOT_DIR/scripts/test_playcover_runtime_stress_live.sh"|true # Runtime stress removed|' \
  "$BACKEND_GATE" >"$missing_stress_gate"
expect_backend_rejected \
  "$missing_stress_gate" \
  "a core aggregate without Runtime protocol/crash stress"

fixture_in_aggregate="$TEST_TEMP/fixture-in-aggregate.sh"
sed \
  '/test_playcover_runtime_stress_live.sh/a\
  bash "$ROOT_DIR/scripts/test_playcover_fixture_live.sh" --live' \
  "$BACKEND_GATE" >"$fixture_in_aggregate"
expect_backend_rejected \
  "$fixture_in_aggregate" \
  "the optional fixture display diagnostic in the core aggregate"

external_in_aggregate="$TEST_TEMP/external-in-aggregate.sh"
sed \
  '/test_playcover_runtime_stress_live.sh/a\
  bash "$ROOT_DIR/scripts/test_playcover_external_app_live.sh" --live' \
  "$BACKEND_GATE" >"$external_in_aggregate"
expect_backend_rejected \
  "$external_in_aggregate" \
  "the optional external-App display diagnostic in the core aggregate"

echo \
  "[playcover-live-workflow-contract] core two-script live aggregate, provisioned runner binding, and run.log-only artifact negative cases PASS"
