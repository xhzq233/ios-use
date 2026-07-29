#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/playcover_timing_stats.jq"
TEST_TEMP="$(
  mktemp -d "/tmp/ios-use-playcover-timing-stats.XXXXXX"
)"

cleanup() {
  case "$TEST_TEMP" in
    /tmp/ios-use-playcover-timing-stats.*|\
    /private/tmp/ios-use-playcover-timing-stats.*)
      /bin/rm -rf -- "$TEST_TEMP"
      ;;
  esac
}
trap cleanup EXIT

fail_contract() {
  echo "[playcover-timing-stats] ERROR: $*" >&2
  exit 1
}

run_build() {
  jq -s -e --arg mode build -f "$FILTER" "$1"
}

run_parse() {
  jq -e --arg mode parse -f "$FILTER" "$1"
}

run_validate() {
  jq -e --arg mode validate -f "$FILTER" "$1"
}

expect_build_rejected() {
  local input="$1"
  local description="$2"
  if run_build "$input" >/dev/null 2>&1; then
    fail_contract "accepted $description"
  fi
}

expect_parse_rejected() {
  local line="$1"
  local description="$2"
  write_parse_input "$TEST_TEMP/rejected-parse-input.json" "$line"
  if run_parse \
    "$TEST_TEMP/rejected-parse-input.json" >/dev/null 2>&1; then
    fail_contract "accepted $description"
  fi
}

expect_validate_rejected() {
  local input="$1"
  local description="$2"
  if run_validate "$input" >/dev/null 2>&1; then
    fail_contract "accepted $description"
  fi
}

GENERATION_KEY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_GENERATION_KEY="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
FIXTURE_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OTHER_FIXTURE_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

write_parse_input() {
  local destination="$1"
  local line="$2"
  jq -n \
    --arg line "$line" \
    --arg case "clean_cycle_01_start" \
    --arg generationKey "$GENERATION_KEY" \
    --arg fixtureAppTreeSHA256 "$FIXTURE_SHA256" \
    '{
      line: $line,
      case: $case,
      generationKey: $generationKey,
      fixtureAppTreeSHA256: $fixtureAppTreeSHA256
    }' >"$destination"
}

BASE_SAMPLES="$TEST_TEMP/base-samples.jsonl"
jq -cn \
  --arg generationKey "$GENERATION_KEY" \
  --arg fixtureAppTreeSHA256 "$FIXTURE_SHA256" \
  '
    ["01", "02", "03", "04", "05"] as $suffixes
    | [1, 2, 3, 4, 100] as $inspect
    | [0, 0, 0, 1, 2] as $alias
    | [null, 1, null, 3, 5] as $runtime
    | range(0; 5) as $index
    | {
        case: "clean_cycle_\($suffixes[$index])_start",
        generationKey: $generationKey,
        fixtureAppTreeSHA256: $fixtureAppTreeSHA256,
        phases: {
          inspect: $inspect[$index],
          verify: ($index + 10),
          launch: ($index + 20),
          alias: $alias[$index],
          openDispatch: ($index + 30),
          exactOwnership: ($index + 40),
          runtimeTransportPing: $runtime[$index],
          readyGeometry: ($index + 50),
          total: ($index + 60)
        }
      }
  ' >"$BASE_SAMPLES"

BASE_SUMMARY="$TEST_TEMP/base-summary.json"
run_build "$BASE_SAMPLES" >"$BASE_SUMMARY"
jq -e \
  --arg generationKey "$GENERATION_KEY" \
  --arg fixtureAppTreeSHA256 "$FIXTURE_SHA256" \
  '
    def near($actual; $expected):
      (($actual - $expected) | abs) < 0.000000001;
    .schemaVersion == 1
    and .unit == "milliseconds"
    and .minimumSampleCount == 5
    and .sampleCount == 5
    and .generationKey == $generationKey
    and .fixtureAppTreeSHA256 == $fixtureAppTreeSHA256
    and .sampleCases == [
      "clean_cycle_01_start",
      "clean_cycle_02_start",
      "clean_cycle_03_start",
      "clean_cycle_04_start",
      "clean_cycle_05_start"
    ]
    and .inputPrecisionMs == {
      inspect: 0.1,
      verify: 0.1,
      launch: 0.1,
      alias: 0.001,
      openDispatch: 0.001,
      exactOwnership: 0.001,
      runtimeTransportPing: 0.001,
      readyGeometry: 0.001,
      total: 0.1
    }
    and (.samples | length) == 5
    and .phases.inspect.observedSampleCount == 5
    and .phases.inspect.skippedSampleCount == 0
    and .phases.inspect.medianMs == 3
    and .phases.inspect.rawMadMs == 1
    and near(.phases.inspect.normalizedMadMs; 1.4826)
    and near(.phases.inspect.relativeMadPercent; (100 / 3))
    and .phases.runtimeTransportPing.observedSampleCount == 3
    and .phases.runtimeTransportPing.skippedSampleCount == 2
    and .phases.runtimeTransportPing.medianMs == 3
    and .phases.runtimeTransportPing.rawMadMs == 2
    and near(.phases.runtimeTransportPing.normalizedMadMs; 2.9652)
    and near(.phases.runtimeTransportPing.relativeMadPercent; (200 / 3))
    and .phases.alias.medianMs == 0
    and .phases.alias.relativeMadPercent == null
  ' "$BASE_SUMMARY" >/dev/null ||
  fail_contract "five-sample odd median/MAD summary is incorrect"
run_validate "$BASE_SUMMARY" >/dev/null

EVEN_SAMPLES="$TEST_TEMP/even-samples.jsonl"
/bin/cp "$BASE_SAMPLES" "$EVEN_SAMPLES"
jq -cn \
  --arg generationKey "$GENERATION_KEY" \
  --arg fixtureAppTreeSHA256 "$FIXTURE_SHA256" \
  '{
    case: "clean_cycle_06_start",
    generationKey: $generationKey,
    fixtureAppTreeSHA256: $fixtureAppTreeSHA256,
    phases: {
      inspect: 200,
      verify: 15,
      launch: 25,
      alias: 3,
      openDispatch: 35,
      exactOwnership: 45,
      runtimeTransportPing: 7,
      readyGeometry: 55,
      total: 65
    }
  }' >>"$EVEN_SAMPLES"
EVEN_SUMMARY="$TEST_TEMP/even-summary.json"
run_build "$EVEN_SAMPLES" >"$EVEN_SUMMARY"
jq -e '
  .sampleCount == 6
  and .phases.inspect.medianMs == 3.5
  and .phases.inspect.rawMadMs == 2
  and .phases.runtimeTransportPing.observedSampleCount == 4
  and .phases.runtimeTransportPing.skippedSampleCount == 2
  and .phases.runtimeTransportPing.medianMs == 4
  and .phases.runtimeTransportPing.rawMadMs == 2
' "$EVEN_SUMMARY" >/dev/null ||
  fail_contract "six-sample even median/MAD summary is incorrect"

FOUR_SAMPLES="$TEST_TEMP/four-samples.jsonl"
sed -n '1,4p' "$BASE_SAMPLES" >"$FOUR_SAMPLES"
expect_build_rejected "$FOUR_SAMPLES" "four samples"

ALL_SKIPPED_SAMPLES="$TEST_TEMP/all-skipped-samples.jsonl"
jq -c \
  '.phases.runtimeTransportPing = null' \
  "$BASE_SAMPLES" >"$ALL_SKIPPED_SAMPLES"
ALL_SKIPPED_SUMMARY="$TEST_TEMP/all-skipped-summary.json"
run_build "$ALL_SKIPPED_SAMPLES" >"$ALL_SKIPPED_SUMMARY"
jq -e '
  .phases.runtimeTransportPing == {
    observedSampleCount: 0,
    skippedSampleCount: 5,
    medianMs: null,
    rawMadMs: null,
    normalizedMadMs: null,
    relativeMadPercent: null
  }
' "$ALL_SKIPPED_SUMMARY" >/dev/null ||
  fail_contract "all-skipped runtimeTransportPing summary is incorrect"

MISSING_SAMPLE_FIELD="$TEST_TEMP/missing-sample-field.jsonl"
jq -c \
  'if .case == "clean_cycle_01_start" then del(.generationKey) else . end' \
  "$BASE_SAMPLES" >"$MISSING_SAMPLE_FIELD"
expect_build_rejected "$MISSING_SAMPLE_FIELD" "a missing sample field"

MISSING_PHASE="$TEST_TEMP/missing-phase.jsonl"
jq -c \
  'if .case == "clean_cycle_01_start" then del(.phases.launch) else . end' \
  "$BASE_SAMPLES" >"$MISSING_PHASE"
expect_build_rejected "$MISSING_PHASE" "a missing phase"

DUPLICATE_CASE="$TEST_TEMP/duplicate-case.jsonl"
jq -c '
  if .case == "clean_cycle_05_start"
  then .case = "clean_cycle_04_start"
  else .
  end
' "$BASE_SAMPLES" >"$DUPLICATE_CASE"
expect_build_rejected "$DUPLICATE_CASE" "a duplicate case"

INVALID_CASE="$TEST_TEMP/invalid-case.jsonl"
jq -c '
  if .case == "clean_cycle_05_start"
  then .case = "cycle_05"
  else .
  end
' "$BASE_SAMPLES" >"$INVALID_CASE"
expect_build_rejected "$INVALID_CASE" "an invalid case name"

NEGATIVE_PHASE="$TEST_TEMP/negative-phase.jsonl"
jq -c '
  if .case == "clean_cycle_01_start"
  then .phases.inspect = -1
  else .
  end
' "$BASE_SAMPLES" >"$NEGATIVE_PHASE"
expect_build_rejected "$NEGATIVE_PHASE" "a negative phase"

NULL_REQUIRED_PHASE="$TEST_TEMP/null-required-phase.jsonl"
jq -c '
  if .case == "clean_cycle_01_start"
  then .phases.readyGeometry = null
  else .
  end
' "$BASE_SAMPLES" >"$NULL_REQUIRED_PHASE"
expect_build_rejected \
  "$NULL_REQUIRED_PHASE" \
  "null outside runtimeTransportPing"

PING_EXCEEDS_OWNERSHIP="$TEST_TEMP/ping-exceeds-ownership.jsonl"
jq -c '
  if .case == "clean_cycle_02_start"
  then
    .phases.exactOwnership = 1
    | .phases.runtimeTransportPing = 1.001
  else
    .
  end
' "$BASE_SAMPLES" >"$PING_EXCEEDS_OWNERSHIP"
expect_build_rejected \
  "$PING_EXCEEDS_OWNERSHIP" \
  "runtimeTransportPing outside its exactOwnership interval"

NAN_PHASE="$TEST_TEMP/nan-phase.jsonl"
sed '1s/"inspect":1/"inspect":NaN/' \
  "$BASE_SAMPLES" >"$NAN_PHASE"
jq -s -e '.[0].phases.inspect | isnan' "$NAN_PHASE" >/dev/null ||
  fail_contract "NaN rejection fixture is not NaN"
expect_build_rejected "$NAN_PHASE" "a NaN phase"

INFINITE_PHASE="$TEST_TEMP/infinite-phase.jsonl"
sed '1s/"inspect":1/"inspect":Infinity/' \
  "$BASE_SAMPLES" >"$INFINITE_PHASE"
jq -s -e '.[0].phases.inspect | isinfinite' \
  "$INFINITE_PHASE" >/dev/null ||
  fail_contract "infinity rejection fixture is not infinite"
expect_build_rejected "$INFINITE_PHASE" "an infinite phase"

UNKNOWN_SAMPLE_FIELD="$TEST_TEMP/unknown-sample-field.jsonl"
jq -c '.unknown = false' \
  "$BASE_SAMPLES" >"$UNKNOWN_SAMPLE_FIELD"
expect_build_rejected "$UNKNOWN_SAMPLE_FIELD" "an unknown sample field"

UNKNOWN_PHASE="$TEST_TEMP/unknown-phase.jsonl"
jq -c '.phases.unknown = 1' \
  "$BASE_SAMPLES" >"$UNKNOWN_PHASE"
expect_build_rejected "$UNKNOWN_PHASE" "an unknown phase"

GENERATION_MISMATCH="$TEST_TEMP/generation-mismatch.jsonl"
jq -c \
  --arg other "$OTHER_GENERATION_KEY" \
  'if .case == "clean_cycle_05_start"
   then .generationKey = $other
   else .
   end' \
  "$BASE_SAMPLES" >"$GENERATION_MISMATCH"
expect_build_rejected "$GENERATION_MISMATCH" "a generation mismatch"

FIXTURE_MISMATCH="$TEST_TEMP/fixture-mismatch.jsonl"
jq -c \
  --arg other "$OTHER_FIXTURE_SHA256" \
  'if .case == "clean_cycle_05_start"
   then .fixtureAppTreeSHA256 = $other
   else .
   end' \
  "$BASE_SAMPLES" >"$FIXTURE_MISMATCH"
expect_build_rejected "$FIXTURE_MISMATCH" "a fixture tree mismatch"

VALID_TIMING_LINE="Mac timing: inspect=1.0ms clone=skipped convert=skipped sign=skipped verify=2.0ms launch=3.0ms alias=4.000ms openDispatch=5.000ms exactOwnership=6.000ms runtimeTransportPing=skipped readyGeometry=7.000ms total=8.0ms"
VALID_PARSE_INPUT="$TEST_TEMP/valid-parse-input.json"
VALID_SAMPLE="$TEST_TEMP/valid-sample.json"
write_parse_input "$VALID_PARSE_INPUT" "$VALID_TIMING_LINE"
run_parse "$VALID_PARSE_INPUT" >"$VALID_SAMPLE"
jq -e \
  --arg generationKey "$GENERATION_KEY" \
  --arg fixtureAppTreeSHA256 "$FIXTURE_SHA256" \
  '
    .case == "clean_cycle_01_start"
    and .generationKey == $generationKey
    and .fixtureAppTreeSHA256 == $fixtureAppTreeSHA256
    and .phases == {
      inspect: 1,
      verify: 2,
      launch: 3,
      alias: 4,
      openDispatch: 5,
      exactOwnership: 6,
      runtimeTransportPing: null,
      readyGeometry: 7,
      total: 8
    }
  ' "$VALID_SAMPLE" >/dev/null ||
  fail_contract "valid skipped timing line parsed incorrectly"

OBSERVED_TIMING_LINE="${VALID_TIMING_LINE/runtimeTransportPing=skipped/runtimeTransportPing=5.500ms}"
write_parse_input \
  "$TEST_TEMP/observed-parse-input.json" \
  "$OBSERVED_TIMING_LINE"
run_parse "$TEST_TEMP/observed-parse-input.json" |
  jq -e '.phases.runtimeTransportPing == 5.5' >/dev/null ||
  fail_contract "valid observed runtimeTransportPing parsed incorrectly"

expect_parse_rejected \
  "${VALID_TIMING_LINE/ alias=4.000ms/}" \
  "a timing line with a missing token"
expect_parse_rejected \
  "${VALID_TIMING_LINE/inspect=1.0ms/inspect=1.0ms inspect=1.0ms}" \
  "a timing line with a duplicate token"
expect_parse_rejected \
  "${VALID_TIMING_LINE/verify=2.0ms/verify=2.0ms unknown=1.0ms}" \
  "a timing line with an unknown token"
expect_parse_rejected \
  "${VALID_TIMING_LINE/inspect=1.0ms/inspect=-1.0ms}" \
  "a negative timing token"
expect_parse_rejected \
  "${VALID_TIMING_LINE/inspect=1.0ms/inspect=NaNms}" \
  "a NaN timing token"
expect_parse_rejected \
  "${VALID_TIMING_LINE/inspect=1.0ms/inspect=Infms}" \
  "an infinite timing token"
expect_parse_rejected \
  "${VALID_TIMING_LINE/inspect=1.0ms/inspect=1.0s}" \
  "a timing token with the wrong unit"
expect_parse_rejected \
  "${VALID_TIMING_LINE/clone=skipped/clone=1.0ms}" \
  "an observed cold-only phase"
expect_parse_rejected \
  "${VALID_TIMING_LINE/runtimeTransportPing=skipped/runtimeTransportPing=skippedms}" \
  "a unit suffix on skipped runtimeTransportPing"
expect_parse_rejected \
  "$VALID_TIMING_LINE"$'\n'"$VALID_TIMING_LINE" \
  "multiple timing payloads"

UNKNOWN_PARSE_FIELD="$TEST_TEMP/unknown-parse-field.json"
jq '.unknown = false' \
  "$VALID_PARSE_INPUT" >"$UNKNOWN_PARSE_FIELD"
if run_parse "$UNKNOWN_PARSE_FIELD" >/dev/null 2>&1; then
  fail_contract "accepted an unknown parse input field"
fi

TAMPERED_MEDIAN="$TEST_TEMP/tampered-median.json"
jq '.phases.inspect.medianMs += 1' \
  "$BASE_SUMMARY" >"$TAMPERED_MEDIAN"
expect_validate_rejected "$TAMPERED_MEDIAN" "a tampered median"

TAMPERED_COUNT="$TEST_TEMP/tampered-count.json"
jq '.phases.runtimeTransportPing.skippedSampleCount = 0' \
  "$BASE_SUMMARY" >"$TAMPERED_COUNT"
expect_validate_rejected "$TAMPERED_COUNT" "a tampered skipped count"

TAMPERED_SAMPLE="$TEST_TEMP/tampered-sample.json"
jq '.samples[0].phases.inspect += 10' \
  "$BASE_SUMMARY" >"$TAMPERED_SAMPLE"
expect_validate_rejected "$TAMPERED_SAMPLE" "a tampered raw sample"

TAMPERED_CASES="$TEST_TEMP/tampered-cases.json"
jq '.sampleCases[0] = "clean_cycle_99_start"' \
  "$BASE_SUMMARY" >"$TAMPERED_CASES"
expect_validate_rejected "$TAMPERED_CASES" "tampered sampleCases"

UNKNOWN_SUMMARY_FIELD="$TEST_TEMP/unknown-summary-field.json"
jq '.unknown = false' \
  "$BASE_SUMMARY" >"$UNKNOWN_SUMMARY_FIELD"
expect_validate_rejected "$UNKNOWN_SUMMARY_FIELD" "an unknown summary field"

echo \
  "[playcover-timing-stats] parse, sample validation, median/MAD, skipped-count, and summary recomputation contract PASS"
