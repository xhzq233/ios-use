#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
ENTRYPOINT="$ROOT_DIR/scripts/test_playcover_external_prepare_differential.sh"
TEST_TEMP="$(
  mktemp -d "/tmp/ios-use-external-prepare-contract.XXXXXX"
)"

cleanup() {
  case "$TEST_TEMP" in
    /tmp/ios-use-external-prepare-contract.*|\
    /private/tmp/ios-use-external-prepare-contract.*)
      /bin/rm -rf -- "$TEST_TEMP"
      ;;
  esac
}
trap cleanup EXIT

fail_contract() {
  echo \
    "[playcover-external-prepare-contract] ERROR: $*" \
    >&2
  exit 1
}

require_last_output() {
  local expected="$1"
  if ! grep -Fq -- "$expected" "$TEST_TEMP/output"; then
    cat "$TEST_TEMP/output" >&2
    fail_contract "missing rejection evidence: $expected"
  fi
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

work_root_sha256() {
  local requested="$1"
  local parent
  parent="$(cd "$(dirname "$requested")" && pwd -P)"
  printf '%s' "$parent/$(basename "$requested")" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}

write_profile_binding() {
  local output="$1"
  local schema="$2"
  local scope="$3"
  local digest="$4"
  jq -n \
    --argjson schema "$schema" \
    --arg scope "$scope" \
    --arg digest "$digest" \
    '{
      schemaVersion: $schema,
      scope: $scope,
      workRootSHA256: $digest
    }' >"$output"
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
  write_profile_binding \
    "$fixture_root/profile.json" \
    2 \
    "external-app-structural-v2" \
    "$(work_root_sha256 "$TEST_TEMP/git-output-$name/work-root")"
  echo '{}' >"$fixture_root/scenario.json"
  echo runtime >"$fixture_root/IOSUsePlayRuntime.framework/input"
  echo playtools >"$fixture_root/PlayTools.framework/input"
  echo tracked >"$fixture_root/tracked.txt"
  /usr/bin/git -C "$fixture_root" init -q
  /usr/bin/git -C "$fixture_root" config user.name "ios-use contract"
  /usr/bin/git -C "$fixture_root" config user.email "contract@example.invalid"
  /usr/bin/git -C "$fixture_root" config commit.gpgsign false
  /usr/bin/git -C "$fixture_root" add .
  /usr/bin/git -C "$fixture_root" commit -qm "fixture"
  fixture_commit="$(
    /usr/bin/git -C "$fixture_root" rev-parse HEAD
  )"
  fixture_profile_sha256="$(
    /usr/bin/shasum -a 256 "$fixture_root/profile.json" |
      /usr/bin/awk '{print $1}'
  )"
  fixture_args=(
    --profile "$fixture_root/profile.json"
    --profile-sha256 "$fixture_profile_sha256"
    --scenario "$fixture_root/scenario.json"
    --runtime "$fixture_root/IOSUsePlayRuntime.framework"
    --playtools "$fixture_root/PlayTools.framework"
    --work-root "$TEST_TEMP/git-output-$name/work-root"
    --attestation "$TEST_TEMP/git-output-$name/attestation.json"
    --commit "$fixture_commit"
  )
}

bash -n "$ENTRYPOINT"

profile="$TEST_TEMP/profile.json"
scenario="$TEST_TEMP/scenario.json"
runtime="$TEST_TEMP/IOSUsePlayRuntime.framework"
playtools="$TEST_TEMP/PlayTools.framework"
work_root="$TEST_TEMP/work-root"
attestation="$TEST_TEMP/attestation.json"
commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"

echo '{}' >"$scenario"
mkdir "$runtime" "$playtools"
write_profile_binding \
  "$profile" \
  2 \
  "external-app-structural-v2" \
  "$(work_root_sha256 "$work_root")"
profile_sha256="$(
  /usr/bin/shasum -a 256 "$profile" | /usr/bin/awk '{print $1}'
)"

full_args=(
  --profile "$profile"
  --profile-sha256 "$profile_sha256"
  --scenario "$scenario"
  --runtime "$runtime"
  --playtools "$playtools"
  --work-root "$work_root"
  --attestation "$attestation"
  --commit "$commit"
)

expect_status 64 "an empty invocation"
expect_status 64 "an unknown argument" --unknown value
expect_status 64 \
  "a duplicate argument" \
  "${full_args[@]}" --profile "$profile"

for pair_index in 0 2 4 6 8 10 12 14; do
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

invalid_profile_hash=("${full_args[@]}")
invalid_profile_hash[3]="ABC"
expect_status 64 \
  "a non-lowercase profile digest" \
  "${invalid_profile_hash[@]}"

v1_profile="$TEST_TEMP/profile-v1.json"
write_profile_binding \
  "$v1_profile" \
  1 \
  "external-app-structural-v1" \
  "$(work_root_sha256 "$work_root")"
v1_profile_args=("${full_args[@]}")
v1_profile_args[1]="$v1_profile"
v1_profile_args[3]="$(
  /usr/bin/shasum -a 256 "$v1_profile" |
    /usr/bin/awk '{print $1}'
)"
expect_status 78 \
  "a schema-v1 profile" \
  "${v1_profile_args[@]}"
require_last_output \
  "profile must use the external-app-structural-v2 schema"

malformed_work_root_profile="$TEST_TEMP/profile-malformed-work-root.json"
write_profile_binding \
  "$malformed_work_root_profile" \
  2 \
  "external-app-structural-v2" \
  "ABC"
malformed_work_root_args=("${full_args[@]}")
malformed_work_root_args[1]="$malformed_work_root_profile"
malformed_work_root_args[3]="$(
  /usr/bin/shasum -a 256 "$malformed_work_root_profile" |
    /usr/bin/awk '{print $1}'
)"
expect_status 78 \
  "a malformed work-root digest" \
  "${malformed_work_root_args[@]}"
require_last_output "with a lowercase work-root SHA-256"

mismatched_work_root_profile="$TEST_TEMP/profile-mismatched-work-root.json"
write_profile_binding \
  "$mismatched_work_root_profile" \
  2 \
  "external-app-structural-v2" \
  "$(printf 'b%.0s' {1..64})"
mismatched_work_root_args=("${full_args[@]}")
mismatched_work_root_args[1]="$mismatched_work_root_profile"
mismatched_work_root_args[3]="$(
  /usr/bin/shasum -a 256 "$mismatched_work_root_profile" |
    /usr/bin/awk '{print $1}'
)"
expect_status 78 \
  "a profile bound to another work root" \
  "${mismatched_work_root_args[@]}"
require_last_output \
  "profile work-root SHA-256 does not match the configured canonical work root"

invalid_commit=("${full_args[@]}")
invalid_commit[15]="ABC"
expect_status 64 \
  "a non-lowercase commit identity" \
  "${invalid_commit[@]}"

lf_work_root=("${full_args[@]}")
lf_work_root[11]="$TEST_TEMP/work"$'\n'"root"
expect_status 64 \
  "a work root containing LF" \
  "${lf_work_root[@]}"
require_last_output "--work-root must not contain CR or LF"

cr_work_root=("${full_args[@]}")
cr_work_root[11]="$TEST_TEMP/work"$'\r'"root"
expect_status 64 \
  "a work root containing CR" \
  "${cr_work_root[@]}"
require_last_output "--work-root must not contain CR or LF"

relative_profile=("${full_args[@]}")
relative_profile[1]="profile.json"
expect_status 64 \
  "a relative configured path" \
  "${relative_profile[@]}"

touch "$attestation"
expect_status 78 \
  "an existing attestation" \
  "${full_args[@]}"
rm "$attestation"

mkdir "$work_root"
expect_status 78 \
  "an existing work root" \
  "${full_args[@]}"
rmdir "$work_root"

checkout_work_args=("${full_args[@]}")
checkout_work_args[11]="$ROOT_DIR/.external-prepare-contract-work"
expect_status 78 \
  "a work root inside the checkout" \
  "${checkout_work_args[@]}"

checkout_attestation_args=("${full_args[@]}")
checkout_attestation_args[13]="$ROOT_DIR/.external-prepare-contract.json"
expect_status 78 \
  "an attestation inside the checkout" \
  "${checkout_attestation_args[@]}"

wrong_commit=("${full_args[@]}")
wrong_commit[15]="0000000000000000000000000000000000000000"
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

prepare_git_fixture same-root
same_root_args=("${fixture_args[@]}")
same_root_args[15]="0000000000000000000000000000000000000000"
expect_entry_status \
  "$fixture_entrypoint" 78 \
  "the exact profile-bound canonical work root" \
  "${same_root_args[@]}"
require_last_output \
  "--commit does not identify the current checkout HEAD"

if ! grep -Fq \
  '/usr/bin/env -i' \
  "$ENTRYPOINT" ||
   ! grep -Fq \
  'PlayCoverExternalPrepareDifferentialTests/testConfiguredExternalAppPassesReviewedStructuralProfile' \
  "$ENTRYPOINT" ||
   ! grep -Fq \
  '.scope == "external-app-structural-v2"' \
  "$ENTRYPOINT" ||
   ! grep -Fq \
  '.workRootSHA256 == $work_root' \
  "$ENTRYPOINT" ||
   ! grep -Fq \
  '.differential.scope == "external-app"' \
  "$ENTRYPOINT"; then
  fail_contract \
    "entrypoint lost its fixed configured-XCTest or exact-attestation contract"
fi

echo \
  "[playcover-external-prepare-contract] required-input, freshness, confinement, clean-HEAD, and fixed-XCTest negative cases PASS"
