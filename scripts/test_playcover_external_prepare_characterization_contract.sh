#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
ENTRYPOINT="$ROOT_DIR/scripts/characterize_playcover_external_prepare.sh"
FORMAL_ENTRYPOINT="$ROOT_DIR/scripts/test_playcover_external_prepare_differential.sh"
SWIFT_TEST="$ROOT_DIR/swift-cli/Tests/IOSUseCLITests/PlayCover/PlayCoverExternalPrepareDifferentialTests.swift"
TEST_TEMP="$(
  mktemp -d \
    "/tmp/ios-use-external-characterization-contract.XXXXXX"
)"

cleanup() {
  case "$TEST_TEMP" in
    /tmp/ios-use-external-characterization-contract.*|\
    /private/tmp/ios-use-external-characterization-contract.*)
      /bin/rm -rf -- "$TEST_TEMP"
      ;;
  esac
}
trap cleanup EXIT

fail_contract() {
  echo \
    "[playcover-external-characterization-contract] ERROR: $*" \
    >&2
  exit 1
}

require_last_output() {
  local expected="$1"
  if ! grep -Fq "$expected" "$TEST_TEMP/output"; then
    cat "$TEST_TEMP/output" >&2
    fail_contract "missing rejection evidence: $expected"
  fi
}

extract_swift_function() {
  local signature="$1"
  /usr/bin/awk -v signature="$signature" '
    index($0, signature) {
      found = 1
    }
    found {
      print
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      depth += opens - closes
      if (opens > 0) {
        started = 1
      }
      if (started && depth == 0) {
        exit
      }
    }
  ' "$SWIFT_TEST"
}

expect_entry_status() {
  local entrypoint="$1"
  local expected="$2"
  local description="$3"
  shift 3
  local actual=0
  bash "$entrypoint" "$@" >"$TEST_TEMP/output" 2>&1 || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    cat "$TEST_TEMP/output" >&2
    fail_contract \
      "$description returned $actual instead of expected $expected"
  fi
}

expect_status() {
  local expected="$1"
  local description="$2"
  shift 2
  expect_entry_status \
    "$ENTRYPOINT" "$expected" "$description" "$@"
}

prepare_git_fixture() {
  local name="$1"
  fixture_root="$TEST_TEMP/git-$name"
  fixture_entrypoint="$fixture_root/scripts/$(basename "$ENTRYPOINT")"
  mkdir -p \
    "$fixture_root/scripts" \
    "$fixture_root/IOSUsePlayRuntime.framework" \
    "$fixture_root/PlayTools.framework" \
    "$TEST_TEMP/git-output-$name"
  cp "$ENTRYPOINT" "$fixture_entrypoint"
  echo '{}' >"$fixture_root/scenario.json"
  echo runtime >"$fixture_root/IOSUsePlayRuntime.framework/input"
  echo playtools >"$fixture_root/PlayTools.framework/input"
  echo tracked >"$fixture_root/tracked.txt"
  /usr/bin/git -C "$fixture_root" init -q
  /usr/bin/git -C "$fixture_root" config user.name "ios-use contract"
  /usr/bin/git -C "$fixture_root" \
    config user.email "contract@example.invalid"
  /usr/bin/git -C "$fixture_root" config commit.gpgsign false
  /usr/bin/git -C "$fixture_root" add .
  /usr/bin/git -C "$fixture_root" commit -qm "fixture"
  fixture_commit="$(
    /usr/bin/git -C "$fixture_root" rev-parse HEAD
  )"
  fixture_args=(
    --scenario "$fixture_root/scenario.json"
    --runtime "$fixture_root/IOSUsePlayRuntime.framework"
    --playtools "$fixture_root/PlayTools.framework"
    --work-root "$TEST_TEMP/git-output-$name/work-root"
    --report "$TEST_TEMP/git-output-$name/report.json"
    --commit "$fixture_commit"
  )
}

bash -n "$ENTRYPOINT"

scenario="$TEST_TEMP/scenario.json"
runtime="$TEST_TEMP/IOSUsePlayRuntime.framework"
playtools="$TEST_TEMP/PlayTools.framework"
work_root="$TEST_TEMP/work-root"
report="$TEST_TEMP/report.json"
commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"

echo '{}' >"$scenario"
mkdir "$runtime" "$playtools"

full_args=(
  --scenario "$scenario"
  --runtime "$runtime"
  --playtools "$playtools"
  --work-root "$work_root"
  --report "$report"
  --commit "$commit"
)

expect_status 64 "an empty invocation"
expect_status 64 "an unknown argument" --unknown value
expect_status 64 \
  "a duplicate argument" \
  "${full_args[@]}" --scenario "$scenario"

for pair_index in 0 2 4 6 8 10; do
  omitted=()
  for ((index = 0; index < ${#full_args[@]}; index += 2)); do
    if [[ "$index" -ne "$pair_index" ]]; then
      omitted+=("${full_args[index]}" "${full_args[index + 1]}")
    fi
  done
  expect_status 64 \
    "an invocation missing ${full_args[pair_index]}" \
    "${omitted[@]}"
done

invalid_commit=("${full_args[@]}")
invalid_commit[11]="ABC"
expect_status 64 \
  "a non-lowercase commit identity" \
  "${invalid_commit[@]}"

for value_index in 1 3 5 7 9; do
  relative=("${full_args[@]}")
  relative[value_index]="relative-input"
  expect_status 64 \
    "a relative value for ${full_args[value_index - 1]}" \
    "${relative[@]}"
done

touch "$report"
expect_status 78 "an existing report" "${full_args[@]}"
rm "$report"

mkdir "$work_root"
expect_status 78 "an existing work root" "${full_args[@]}"
rmdir "$work_root"

checkout_work=("${full_args[@]}")
checkout_work[7]="$ROOT_DIR/.external-characterization-work"
expect_status 78 \
  "a work root inside the checkout" \
  "${checkout_work[@]}"

checkout_report=("${full_args[@]}")
checkout_report[9]="$ROOT_DIR/.external-characterization.json"
expect_status 78 \
  "a report inside the checkout" \
  "${checkout_report[@]}"

wrong_commit=("${full_args[@]}")
wrong_commit[11]="0000000000000000000000000000000000000000"
expect_status 78 \
  "a commit other than checkout HEAD" \
  "${wrong_commit[@]}"

prepare_git_fixture tracked-dirty
echo changed >>"$fixture_root/tracked.txt"
expect_entry_status \
  "$fixture_entrypoint" 78 \
  "a tracked working-tree change" \
  "${fixture_args[@]}"
require_last_output "tracked working tree differs from the index"

prepare_git_fixture index-dirty
echo changed >>"$fixture_root/tracked.txt"
/usr/bin/git -C "$fixture_root" add tracked.txt
expect_entry_status \
  "$fixture_entrypoint" 78 \
  "an index change" \
  "${fixture_args[@]}"
require_last_output "index differs from the committed HEAD"

prepare_git_fixture untracked
echo untracked >"$fixture_root/untracked.txt"
expect_entry_status \
  "$fixture_entrypoint" 78 \
  "an untracked non-ignored file" \
  "${fixture_args[@]}"
require_last_output "checkout has untracked non-ignored files"

expected_filter="PlayCoverExternalPrepareDifferentialTests/testConfiguredExternalAppWritesDiagnosticCharacterization"
if [[ "$(grep -Fc -- '--filter "$XCTEST_FILTER"' "$ENTRYPOINT")" != "1" ]] ||
   ! grep -Fq "XCTEST_FILTER=\"$expected_filter\"" "$ENTRYPOINT" ||
   ! grep -Fq "/usr/bin/env -i" "$ENTRYPOINT"; then
  fail_contract \
    "entrypoint lost its cleared environment or fixed XCTest"
fi

diagnostic_body="$(
  extract_swift_function \
    "func testConfiguredExternalAppWritesDiagnosticCharacterization()"
)"
formal_body="$(
  extract_swift_function \
    "func testConfiguredExternalAppPassesReviewedStructuralProfile()"
)"
if ! grep -Fq \
  "PlayCoverPrepareDifferentialGate.differences(" \
  <<<"$diagnostic_body" ||
   ! grep -Fq \
     "pinnedResult: comparison.pinnedResult" \
     <<<"$diagnostic_body"; then
  fail_contract \
    "diagnostic XCTest lost its typed raw-difference call"
fi
all_conclusion_calls="$(
  grep -Ec \
    'PlayCoverPrepareDifferentialGate\.(attest|enforce)' \
    "$SWIFT_TEST" ||
    true
)"
formal_conclusion_calls="$(
  grep -Ec \
    'PlayCoverPrepareDifferentialGate\.(attest|enforce)' \
    <<<"$formal_body" ||
    true
)"
if [[ "$formal_conclusion_calls" == "0" ]] ||
   [[ "$all_conclusion_calls" != "$formal_conclusion_calls" ]]; then
  fail_contract \
    "conclusion-producing APIs must remain confined to the formal XCTest"
fi
if grep -Fq \
  "characterize_playcover_external_prepare" \
  "$FORMAL_ENTRYPOINT"; then
  fail_contract \
    "formal differential entrypoint must not depend on characterization"
fi

for recursive_guard in \
  "def all_key_names:" \
  "def all_string_values:" \
  "pass|profile|allowance|attestation" \
  'test("reason|symbol")'; do
  if ! grep -Fq "$recursive_guard" "$ENTRYPOINT"; then
    fail_contract \
      "report validation lost recursive guard: $recursive_guard"
  fi
done

for forbidden in pass profile allowance attestation; do
  nested="$TEST_TEMP/nested-$forbidden.json"
  jq -n \
    --arg key "${forbidden}Field" \
    --arg word "$forbidden" \
    '{outer: {($key): {value: $word}}}' >"$nested"
  if jq -e '
      def forbidden_word:
        ascii_downcase
        | test("pass|profile|allowance|attestation");
      def all_key_names:
        [paths | .[] | select(type == "string")];
      def all_string_values:
        [.. | select(type == "string")];
      all_key_names + all_string_values
      | all(.[]; forbidden_word | not)
    ' "$nested" >/dev/null; then
    fail_contract \
      "recursive scalar guard accepted nested forbidden word: $forbidden"
  fi
done

echo \
  "[playcover-external-characterization-contract] required-input, freshness, confinement, clean-HEAD, fixed-XCTest, and recursive-report negative cases OK"
