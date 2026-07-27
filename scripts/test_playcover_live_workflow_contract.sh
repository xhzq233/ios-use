#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
FIXTURE_GATE="$ROOT_DIR/scripts/test_playcover_fixture_live.sh"
EXTERNAL_GATE="$ROOT_DIR/scripts/test_playcover_external_app_live.sh"
DISPLAY_MATRIX="$ROOT_DIR/playcover-fixtures/live-matrix-v2.tsv"
MOUSE_HELPER_SOURCE="$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift"
MOUSE_CONTRACT_SOURCE="$ROOT_DIR/playcover-fixtures/appkit_mouse_event_contract_tests.swift"
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

require_exact_line() {
  local file="$1"
  local expected="$2"
  local description="$3"
  if [[ "$(count_fixed_line "$file" "$expected")" != "1" ]]; then
    fail_contract "$description must appear exactly once"
  fi
}

validate_workflow() {
  local file="$1"

  require_exact_line \
    "$file" \
    '      IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR: ${{ runner.temp }}/ios-use-playcover-live-attestation-${{ github.run_id }}' \
    "the runner-temp live attestation directory" ||
    return 1
  require_exact_line \
    "$file" \
    '      IOS_USE_PLAYCOVER_LIVE_RUN_DIR: ${{ runner.temp }}/ios-use-playcover-live-run-${{ github.run_id }}' \
    "the runner-temp live metadata/log directory" ||
    return 1
  if [[ "$(
    count_pattern \
      "$file" \
      '^[[:space:]]*IOS_USE_PLAYCOVER_LIVE_(ATTESTATION_DIR|RUN_DIR):'
  )" != "2" ]]; then
    fail_contract "live workflow directories must each have one definition"
    return 1
  fi

  require_exact_line \
    "$file" \
    '          } > "$IOS_USE_PLAYCOVER_LIVE_RUN_DIR/run-metadata.txt"' \
    "runner-private live metadata output" ||
    return 1
  require_exact_line \
    "$file" \
    '            tee "$IOS_USE_PLAYCOVER_LIVE_RUN_DIR/run.log"' \
    "runner-private live log output" ||
    return 1
  if [[ "$(count_pattern "$file" 'run-metadata\.txt')" != "1" ]]; then
    fail_contract "live run metadata must have one runner-private destination"
    return 1
  fi
  if [[ "$(count_pattern "$file" 'run\.log')" != "1" ]]; then
    fail_contract "live run log must have one runner-private destination"
    return 1
  fi

  require_exact_line \
    "$file" \
    '      IOS_USE_PLAYCOVER_LIVE_EVIDENCE_SCHEMA: "2"' \
    "schema-v2 live evidence request" ||
    return 1
  require_exact_line \
    "$file" \
    '          attestation="$IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR/external-app-live-v2.json"' \
    "schema-v2 attestation verifier" ||
    return 1
  require_exact_line \
    "$file" \
    '              .displayMatrix.phases == [' \
    "exact display phase verifier" ||
    return 1
  require_exact_line \
    "$file" \
    '          path: ${{ env.IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR }}/external-app-live-v2.json' \
    "single-file redacted live attestation upload" ||
    return 1
  if [[ "$(
    count_pattern \
      "$file" \
      '^[[:space:]]*path:.*IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR'
  )" != "1" ]]; then
    fail_contract "the live artifact must have one exact attestation path"
    return 1
  fi
}

validate_display_matrix() {
  local file="$1"
  if [[ "$(sed -n '1p' "$file")" != \
    $'matrixVersion\tcase\ttargetScreen\tdisplayScale\tcrossDisplay' ]]; then
    fail_contract "display matrix header is not exact"
    return 1
  fi
  require_exact_line \
    "$file" \
    $'2\thost_main_075\tmain\t0.750\tfalse' \
    "main 0.75 phase" ||
    return 1
  require_exact_line \
    "$file" \
    $'2\thost_extended_100\textended\t1.000\ttrue' \
    "extended 1.0 phase" ||
    return 1
  require_exact_line \
    "$file" \
    $'2\thost_main_0875\tmain\t0.875\ttrue' \
    "main 0.875 phase" ||
    return 1
  if [[ "$(wc -l <"$file" | tr -d ' ')" != "4" ]]; then
    fail_contract "display matrix must contain exactly three phases"
    return 1
  fi
}

validate_live_gate_source() {
  local file="$1"
  if [[ "$(
    count_pattern \
      "$file" \
      '^[[:space:]]*\.windowNumberMatched == true and$'
  )" != "2" ]]; then
    fail_contract \
      "move and resize must each assert the exact expected window match"
    return 1
  fi
  require_exact_line \
    "$file" \
    '          .crossDisplayDrag == true and' \
    "interpolated cross-display drag assertion" ||
    return 1
  require_exact_line \
    "$file" \
    '        (($firstWindow.displayScale - 0.75) | abs) <= 0.01 and' \
    "fixed 0.75 display scale" ||
    return 1
  require_exact_line \
    "$file" \
    '        (($secondWindow.displayScale - 1.0) | abs) <= 0.01 and' \
    "fixed 1.0 display scale" ||
    return 1
  require_exact_line \
    "$file" \
    '        (($thirdWindow.displayScale - 0.875) | abs) <= 0.01' \
    "fixed 0.875 display scale" ||
    return 1
}

expect_rejected() {
  local file="$1"
  local description="$2"
  if validate_workflow "$file" >/dev/null 2>&1; then
    echo \
      "[playcover-live-workflow-contract] ERROR: accepted $description" \
      >&2
    exit 1
  fi
}

expect_matrix_rejected() {
  local file="$1"
  local description="$2"
  if validate_display_matrix "$file" >/dev/null 2>&1; then
    echo \
      "[playcover-live-workflow-contract] ERROR: accepted $description" \
      >&2
    exit 1
  fi
}

expect_gate_source_rejected() {
  local file="$1"
  local description="$2"
  if validate_live_gate_source "$file" >/dev/null 2>&1; then
    echo \
      "[playcover-live-workflow-contract] ERROR: accepted $description" \
      >&2
    exit 1
  fi
}

validate_workflow "$WORKFLOW"
validate_display_matrix "$DISPLAY_MATRIX"
validate_live_gate_source "$FIXTURE_GATE"
validate_live_gate_source "$EXTERNAL_GATE"
/usr/bin/xcrun swiftc \
  "$MOUSE_HELPER_SOURCE" \
  -o "$TEST_TEMP/appkit_mouse_event"
/usr/bin/xcrun swiftc \
  "$MOUSE_CONTRACT_SOURCE" \
  -o "$TEST_TEMP/appkit_mouse_event_contract_tests"
"$TEST_TEMP/appkit_mouse_event_contract_tests" \
  "$TEST_TEMP/appkit_mouse_event"

attestation_in_checkout="$TEST_TEMP/attestation-in-checkout.yml"
sed \
  's#${{ runner.temp }}/ios-use-playcover-live-attestation-${{ github.run_id }}#${{ github.workspace }}/playcover-live-attestation#' \
  "$WORKFLOW" >"$attestation_in_checkout"
expect_rejected \
  "$attestation_in_checkout" \
  "a live attestation directory below github.workspace"

run_data_in_checkout="$TEST_TEMP/run-data-in-checkout.yml"
sed \
  's#${{ runner.temp }}/ios-use-playcover-live-run-${{ github.run_id }}#${{ github.workspace }}/playcover-live-run#' \
  "$WORKFLOW" >"$run_data_in_checkout"
expect_rejected \
  "$run_data_in_checkout" \
  "live run metadata and logs below github.workspace"

directory_upload="$TEST_TEMP/directory-upload.yml"
sed \
  's#path: ${{ env.IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR }}/external-app-live-v2.json#path: ${{ env.IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR }}/#' \
  "$WORKFLOW" >"$directory_upload"
expect_rejected \
  "$directory_upload" \
  "an entire live attestation directory upload"

schema_v1="$TEST_TEMP/schema-v1.yml"
sed \
  's/IOS_USE_PLAYCOVER_LIVE_EVIDENCE_SCHEMA: "2"/IOS_USE_PLAYCOVER_LIVE_EVIDENCE_SCHEMA: "1"/' \
  "$WORKFLOW" >"$schema_v1"
expect_rejected "$schema_v1" "a schema-v1 live evidence request"

variable_scale="$TEST_TEMP/variable-scale.tsv"
sed \
  $'s/2\\thost_extended_100\\textended\\t1.000\\ttrue/2\\thost_extended_100\\textended\\t0.950\\ttrue/' \
  "$DISPLAY_MATRIX" >"$variable_scale"
expect_matrix_rejected \
  "$variable_scale" \
  "a variable extended-display scale"

unbound_window="$TEST_TEMP/unbound-window.sh"
sed 's/\.windowNumberMatched == true and/.windowNumberMatched != true and/g' \
  "$EXTERNAL_GATE" >"$unbound_window"
expect_gate_source_rejected \
  "$unbound_window" \
  "a cross-display drag without exact window matching"

echo \
  "[playcover-live-workflow-contract] display matrix v2, AppKit helper, runner-temp outputs, and exact v2 artifact negative cases PASS"
