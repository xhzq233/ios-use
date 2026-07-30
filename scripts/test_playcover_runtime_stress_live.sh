#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI=""
BUILT_RUNTIME_FRAMEWORK="$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
RUNTIME_EXECUTABLE=""
FIXTURE_APP=""
PROBE_SOURCE="$ROOT_DIR/playcover-fixtures/runtime_socket_probe.swift"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_EVIDENCE_ROOT:-$ROOT_DIR/.ios-use/live-evidence}"
EVIDENCE_PARENT="$EVIDENCE_ROOT/playcover-runtime-stress-v3"
BUILD_ROOT=""
CLI_SCRATCH_PATH=""
FIXTURE_DERIVED_DATA=""
RUN_ID=""
RUN_DIR=""
SESSION_HOME=""
CANONICAL_SESSION_HOME=""
ARCHIVED_SESSION_HOME=""
MANIFEST=""
CLEAN_CYCLE_INDEX=""
OBSERVATIONS=""
ATTESTATION=""
CLEAN_CYCLE_COUNT=20
GATE_PASSED=0
GATE_FAILURE=""
ATTESTATION_WRITTEN=0
PROTOCOL_GENERATION_KEY=""
START_GIT_HEAD=""
CLI_SHA256=""
RUNTIME_EXECUTABLE_SHA256=""
FIXTURE_EXECUTABLE_SHA256=""
FIXTURE_INFO_PLIST_SHA256=""
FIXTURE_APP_TREE_SHA256=""
PROBE_SOURCE_SHA256=""
HEALTHY_STATUS_CASE=""

config_fail() {
  GATE_FAILURE="EX_CONFIG: $*"
  echo "[playcover-runtime-stress] EX_CONFIG: $*" >&2
  exit 78
}

fail_gate() {
  GATE_FAILURE="$*"
  echo "[playcover-runtime-stress] FAIL: $*" >&2
  exit 1
}

repository_status() {
  git -C "$ROOT_DIR" status \
    --porcelain=v1 \
    --untracked-files=all \
    --ignore-submodules=none
}

assert_initial_repository_state() {
  local status
  START_GIT_HEAD="$(
    git -C "$ROOT_DIR" rev-parse --verify HEAD
  )" || config_fail "could not resolve the current checkout HEAD"
  if [[
    ! "$START_GIT_HEAD" =~ ^[0-9a-f]{40}$ &&
    ! "$START_GIT_HEAD" =~ ^[0-9a-f]{64}$
  ]]; then
    config_fail "current checkout HEAD is not an exact Git object ID"
  fi
  status="$(repository_status)" ||
    config_fail "could not inspect the current checkout status"
  if [[ -n "$status" ]]; then
    printf '%s\n' "$status" >&2
    config_fail \
      "current checkout must have no tracked or untracked changes"
  fi
}

assert_repository_unchanged() {
  local end_git_head
  local status
  end_git_head="$(
    git -C "$ROOT_DIR" rev-parse --verify HEAD
  )" || fail_gate "could not resolve checkout HEAD after the gate"
  if [[ "$end_git_head" != "$START_GIT_HEAD" ]]; then
    fail_gate \
      "checkout HEAD changed during the gate ($START_GIT_HEAD -> $end_git_head)"
  fi
  status="$(repository_status)" ||
    fail_gate "could not inspect checkout status after the gate"
  if [[ -n "$status" ]]; then
    printf '%s\n' "$status" >&2
    fail_gate \
      "checkout gained tracked or untracked changes during the gate"
  fi
}

sha256_file() {
  local path="$1"
  local digest
  digest="$(
    /usr/bin/shasum -a 256 -- "$path" |
      /usr/bin/awk '{ print $1 }'
  )" || return 1
  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  printf '%s\n' "$digest"
}

sha256_tree() {
  local root="$1"
  local digest
  if [[ ! -d "$root" || -L "$root" ]]; then
    return 1
  fi
  digest="$(
    (
      cd "$root" || exit 1
      while IFS= read -r -d '' relative; do
        local mode
        local record
        mode="$(/usr/bin/stat -f '%Lp' "$relative")" || exit 1
        if [[ -L "$relative" ]]; then
          local target
          local target_hash
          target="$(/usr/bin/readlink "$relative")" || exit 1
          target_hash="$(
            printf '%s' "$target" | /usr/bin/shasum -a 256 |
              /usr/bin/awk '{ print $1 }'
          )" || exit 1
          record="symlink:$mode:$target_hash"
        elif [[ -f "$relative" ]]; then
          local file_hash
          local file_size
          file_hash="$(sha256_file "$relative")" || exit 1
          file_size="$(/usr/bin/stat -f '%z' "$relative")" || exit 1
          record="file:$mode:$file_size:$file_hash"
        elif [[ -d "$relative" ]]; then
          record="directory:$mode"
        else
          exit 1
        fi
        printf '%s\0%s\0' "$relative" "$record"
      done < <(
        /usr/bin/find . -mindepth 1 -print0 |
          LC_ALL=C /usr/bin/sort -z
      )
    ) |
      /usr/bin/shasum -a 256 |
      /usr/bin/awk '{ print $1 }'
  )" || return 1
  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  printf '%s\n' "$digest"
}

assert_file_hash_unchanged() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local observed
  observed="$(sha256_file "$path")" ||
    fail_gate "could not re-hash $label after the gate"
  if [[ "$observed" != "$expected" ]]; then
    fail_gate "$label changed while the gate was running"
  fi
}

assert_tree_hash_unchanged() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local observed
  observed="$(sha256_tree "$path")" ||
    fail_gate "could not re-hash $label after the gate"
  if [[ "$observed" != "$expected" ]]; then
    fail_gate "$label changed while the gate was running"
  fi
}

assert_built_inputs_unchanged() {
  assert_file_hash_unchanged \
    "$CLI" \
    "$CLI_SHA256" \
    "the fresh CLI"
  assert_file_hash_unchanged \
    "$RUNTIME_EXECUTABLE" \
    "$RUNTIME_EXECUTABLE_SHA256" \
    "the fresh Runtime executable"
  assert_file_hash_unchanged \
    "$FIXTURE_EXECUTABLE" \
    "$FIXTURE_EXECUTABLE_SHA256" \
    "the fresh fixture executable"
  assert_file_hash_unchanged \
    "$FIXTURE_APP/Info.plist" \
    "$FIXTURE_INFO_PLIST_SHA256" \
    "the fresh fixture Info.plist"
  assert_tree_hash_unchanged \
    "$FIXTURE_APP" \
    "$FIXTURE_APP_TREE_SHA256" \
    "the complete fresh fixture App"
  assert_file_hash_unchanged \
    "$PROBE_SOURCE" \
    "$PROBE_SOURCE_SHA256" \
    "the Runtime socket probe source"
}

validate_pass_attestation() {
  local candidate="$1"
  jq -e \
    --arg runID "$RUN_ID" \
    --arg gitHEAD "$START_GIT_HEAD" \
    --arg cliSHA256 "$CLI_SHA256" \
    --arg runtimeExecutableSHA256 "$RUNTIME_EXECUTABLE_SHA256" \
    --arg fixtureExecutableSHA256 "$FIXTURE_EXECUTABLE_SHA256" \
    --arg fixtureInfoPlistSHA256 "$FIXTURE_INFO_PLIST_SHA256" \
    --arg fixtureAppTreeSHA256 "$FIXTURE_APP_TREE_SHA256" \
    --arg probeSourceSHA256 "$PROBE_SOURCE_SHA256" \
    --arg generationKey "$PROTOCOL_GENERATION_KEY" \
    --argjson expectedCleanCycles "$CLEAN_CYCLE_COUNT" '
      def is_sha256:
        type == "string" and test("^[0-9a-f]{64}$");
      def expected_protocol_modes:
        [
          "exact-limit-invalid-json",
          "invalid-utf8",
          "malformed-json",
          "oversized-frame",
          "truncated-frame",
          "zero-length"
        ];
      def expected_clean_cases($count):
        (
          [
            "protocol_stopped",
            "endpoint_stopped",
            "crash_recovery_stopped"
          ] +
          [
            range(1; $count + 1) |
            . as $cycle |
            "clean_cycle_" +
              (if $cycle < 10 then "0" else "" end) +
              ($cycle | tostring) +
              "_stopped"
          ]
        ) | sort;
      (
        .observations |
        map(select(.kind == "protocol-boundary"))
      ) as $protocol |
      (
        .observations |
        map(select(.kind == "hello-readiness-shape"))
      ) as $readiness |
      (
        .observations |
        map(select(.kind == "clean-stop"))
      ) as $cleanStops |
      (
        .observations |
        map(select(.kind == "endpoint-loss"))
      ) as $endpointLoss |
      (
        .observations |
        map(select(.kind == "app-sigkill"))
      ) as $sigkill |
      (
        .observations |
        map(select(.kind == "app-crash-recovery"))
      ) as $recovery |
      .schemaVersion == 3 and
      .gate == "playcover-runtime-stress" and
      .result == "pass" and
      .detail == null and
      (.runID == $runID) and
      (
        .runID |
        type == "string" and
        test("^run\\.[0-9A-Za-z]+$")
      ) and
      (.gitHEAD == $gitHEAD) and
      (
        .gitHEAD |
        type == "string" and
        test("^[0-9a-f]{40}([0-9a-f]{24})?$")
      ) and
      (.cliSHA256 == $cliSHA256) and
      (.cliSHA256 | is_sha256) and
      (
        .runtimeExecutableSHA256 ==
          $runtimeExecutableSHA256
      ) and
      (.runtimeExecutableSHA256 | is_sha256) and
      (
        .fixtureExecutableSHA256 ==
          $fixtureExecutableSHA256
      ) and
      (.fixtureExecutableSHA256 | is_sha256) and
      (
        .fixtureInfoPlistSHA256 ==
          $fixtureInfoPlistSHA256
      ) and
      (.fixtureInfoPlistSHA256 | is_sha256) and
      (.fixtureAppTreeSHA256 == $fixtureAppTreeSHA256) and
      (.fixtureAppTreeSHA256 | is_sha256) and
      (.probeSourceSHA256 == $probeSourceSHA256) and
      (.probeSourceSHA256 | is_sha256) and
      (.generationKey == $generationKey) and
      (.generationKey | is_sha256) and
      .expectedCleanCycles == $expectedCleanCycles and
      .summary.helloReadinessShapeCount == 1 and
      .summary.protocolBoundaryCount == 6 and
      .summary.cleanStopCount ==
        ($expectedCleanCycles + 3) and
      .summary.endpointLossCount == 1 and
      .summary.appSIGKILLCount == 1 and
      .summary.appCrashRecoveryCount == 1 and
      (.observations | length) ==
        ($expectedCleanCycles + 13) and
      ($readiness | length) == 1 and
      (
        $readiness |
        all(
          .responseBytes > 0 and
          .readinessAppKitFieldCount == 27 and
          .statusOnlyAppKitFieldCount == 0 and
          .fullStatusDiagnosticsVerified == true and
          .runtimeListenerSurvived == true and
          .postProbeSessionHealthy == true
        )
      ) and
      ($protocol | length) == 6 and
      (
        $protocol |
        map(.mode) |
        sort
      ) == expected_protocol_modes and
      (
        $protocol |
        all(
          (.runtimeListenerSurvived == true) and
          (.postProbeSessionHealthy == true) and
          (
            (
              (
                .mode == "oversized-frame" or
                .mode == "zero-length"
              ) and
              .runtimeErrorCode == "invalid_frame"
            ) or
            (
              (
                .mode == "malformed-json" or
                .mode == "invalid-utf8" or
                .mode == "exact-limit-invalid-json"
              ) and
              .runtimeErrorCode == "invalid_json"
            ) or
            (
              .mode == "truncated-frame" and
              .runtimeErrorCode == "connection_closed"
            )
          )
        )
      ) and
      ($cleanStops | length) ==
        ($expectedCleanCycles + 3) and
      (
        $cleanStops |
        map(.case) |
        sort
      ) == expected_clean_cases($expectedCleanCycles) and
      (
        $cleanStops |
        all(
          (.runnerPid | type) == "number" and
          .runnerPid > 1 and
          (.runtimeSocketPath | type) == "string" and
          (
            .runtimeSocketPath |
            test("/mac/run/s-[^/]+\\.sock$")
          ) and
          .driverLockAbsent == true and
          .runnerPidAbsent == true and
          .runtimeSocketAbsent == true
        )
      ) and
      ($endpointLoss | length) == 1 and
      (
        $endpointLoss[0] |
        (.runnerPid | type) == "number" and
        .runnerPid > 1 and
        (.runtimeSocketPath | type) == "string" and
        (
          .runtimeSocketPath |
          test("/mac/run/s-[^/]+\\.sock$")
        ) and
        .driverStatus == "unhealthy" and
        .runtimeStatus == "unhealthy" and
        .runtimeIdentityVerified == false and
        .appRemainedAlive == true
      ) and
      ($sigkill | length) == 1 and
      (
        $sigkill[0] |
        (.runnerPid | type) == "number" and
        .runnerPid > 1 and
        (.runtimeSocketPath | type) == "string" and
        (
          .runtimeSocketPath |
          test("/mac/run/s-[^/]+\\.sock$")
        ) and
        (.stdioLogPath | type) == "string" and
        (
          .stdioLogPath |
          test("/mac/logs/stdio-[0-9a-f-]{36}\\.log$")
        ) and
        (
          .stdioLogIdentity |
          type == "string" and
          test("^[0-9]+:[0-9]+:[0-9]+:600:1$")
        ) and
        .stdioMarkersObservedWhileAlive == true and
        .stdioLogRetainedAfterCrashAndStop == true and
        .staleSessionObserved == true and
        .trigger == "fixture-darwin-notification" and
        .selfTriggered == true and
        .driverLockAbsentAfterStop == true and
        .runnerPidAbsentAfterStop == true and
        .exactResiduePreserved == true and
        (
          .residueIdentityBefore |
          type == "string" and
          test("^[0-9]+:[0-9]+:[0-9]+:[0-7]{3,4}$")
        ) and
        .residueIdentityAfterStop ==
          .residueIdentityBefore
      ) and
      ($recovery | length) == 1 and
      (
        $recovery[0] |
        (.staleRuntimeSocketPath | type) == "string" and
        (.freshRuntimeSocketPath | type) == "string" and
        .staleRuntimeSocketPath !=
          .freshRuntimeSocketPath and
        .freshPathDifferent == true and
        .freshSessionStoppedCleanly == true and
        .staleResidueUnchanged == true and
        (
          .staleResidueIdentityBefore |
          type == "string" and
          test("^[0-9]+:[0-9]+:[0-9]+:[0-7]{3,4}$")
        ) and
        .staleResidueIdentityAfterRecovery ==
          .staleResidueIdentityBefore
      )
    ' "$candidate" >/dev/null
}

write_attestation() {
  local result="$1"
  local detail="$2"
  local candidate
  if [[ "$ATTESTATION_WRITTEN" == "1" ]]; then
    return 0
  fi
  if [[ -e "$ATTESTATION" || -L "$ATTESTATION" ]]; then
    echo \
      "[playcover-runtime-stress] refusing existing attestation path: $ATTESTATION" \
      >&2
    return 1
  fi
  candidate="$(
    mktemp "$RUN_DIR/.attestation.candidate.XXXXXX"
  )" || return 1
  if ! /bin/chmod 600 "$candidate"; then
    /bin/rm -f -- "$candidate"
    return 1
  fi
  jq -s \
    --arg result "$result" \
    --arg detail "$detail" \
    --arg runID "$RUN_ID" \
    --arg gitHEAD "$START_GIT_HEAD" \
    --arg cliSHA256 "$CLI_SHA256" \
    --arg runtimeExecutableSHA256 "$RUNTIME_EXECUTABLE_SHA256" \
    --arg fixtureExecutableSHA256 "$FIXTURE_EXECUTABLE_SHA256" \
    --arg fixtureInfoPlistSHA256 "$FIXTURE_INFO_PLIST_SHA256" \
    --arg fixtureAppTreeSHA256 "$FIXTURE_APP_TREE_SHA256" \
    --arg probeSourceSHA256 "$PROBE_SOURCE_SHA256" \
    --arg generationKey "$PROTOCOL_GENERATION_KEY" \
    --argjson expectedCleanCycles "$CLEAN_CYCLE_COUNT" '
      . as $observations |
      {
        schemaVersion: 3,
        gate: "playcover-runtime-stress",
        result: $result,
        detail: (
          if $detail == "" then null else $detail end
        ),
        runID: $runID,
        gitHEAD: (
          if $gitHEAD == "" then null else $gitHEAD end
        ),
        cliSHA256: (
          if $cliSHA256 == "" then null else $cliSHA256 end
        ),
        runtimeExecutableSHA256: (
          if $runtimeExecutableSHA256 == ""
          then null
          else $runtimeExecutableSHA256
          end
        ),
        fixtureExecutableSHA256: (
          if $fixtureExecutableSHA256 == ""
          then null
          else $fixtureExecutableSHA256
          end
        ),
        fixtureInfoPlistSHA256: (
          if $fixtureInfoPlistSHA256 == ""
          then null
          else $fixtureInfoPlistSHA256
          end
        ),
        fixtureAppTreeSHA256: (
          if $fixtureAppTreeSHA256 == ""
          then null
          else $fixtureAppTreeSHA256
          end
        ),
        probeSourceSHA256: (
          if $probeSourceSHA256 == ""
          then null
          else $probeSourceSHA256
          end
        ),
        generationKey: (
          if $generationKey == ""
          then null
          else $generationKey
          end
        ),
        expectedCleanCycles: $expectedCleanCycles,
        summary: {
          helloReadinessShapeCount: (
            [$observations[] |
              select(.kind == "hello-readiness-shape")] |
            length
          ),
          protocolBoundaryCount: (
            [$observations[] |
              select(.kind == "protocol-boundary")] |
            length
          ),
          cleanStopCount: (
            [$observations[] |
              select(.kind == "clean-stop")] |
            length
          ),
          endpointLossCount: (
            [$observations[] |
              select(.kind == "endpoint-loss")] |
            length
          ),
          appSIGKILLCount: (
            [$observations[] |
              select(.kind == "app-sigkill")] |
            length
          ),
          appCrashRecoveryCount: (
            [$observations[] |
              select(.kind == "app-crash-recovery")] |
            length
          )
        },
        observations: $observations
      }
    ' "$OBSERVATIONS" >"$candidate" ||
    {
      /bin/rm -f -- "$candidate"
      return 1
    }
  if [[
    ! -f "$candidate" ||
    -L "$candidate" ||
    "$(stat -f '%Lp' "$candidate")" != "600"
  ]]; then
    /bin/rm -f -- "$candidate"
    return 1
  fi
  if [[ "$result" == "pass" ]] &&
      ! validate_pass_attestation "$candidate"; then
    /bin/rm -f -- "$candidate"
    return 1
  fi
  if [[ -e "$ATTESTATION" || -L "$ATTESTATION" ]] ||
      ! /bin/ln "$candidate" "$ATTESTATION"; then
    /bin/rm -f -- "$candidate"
    return 1
  fi
  if [[
    ! -f "$ATTESTATION" ||
    -L "$ATTESTATION" ||
    "$(stat -f '%Lp' "$ATTESTATION")" != "600"
  ]]; then
    /bin/unlink "$ATTESTATION" 2>/dev/null || true
    /bin/rm -f -- "$candidate"
    return 1
  fi
  ATTESTATION_WRITTEN=1
  /bin/rm -f -- "$candidate" || true
}

archive_and_remove_session_home() {
  if [[ ! -d "$SESSION_HOME" ]]; then
    return 0
  fi
  if [[
    "$SESSION_HOME" != /tmp/iups.* ||
    -L "$SESSION_HOME"
  ]]; then
    echo \
      "[playcover-runtime-stress] refusing unexpected IOS_USE_HOME: $SESSION_HOME" \
      >&2
    return 1
  fi
  if [[ -e "$ARCHIVED_SESSION_HOME" || -L "$ARCHIVED_SESSION_HOME" ]]; then
    echo \
      "[playcover-runtime-stress] refusing to replace archived session evidence" \
      >&2
    return 1
  fi
  if ! /usr/bin/ditto "$SESSION_HOME" "$ARCHIVED_SESSION_HOME"; then
    echo \
      "[playcover-runtime-stress] session archive failed; source preserved at $SESSION_HOME" \
      >&2
    return 1
  fi
  if ! /bin/rm -rf -- "$SESSION_HOME"; then
    echo \
      "[playcover-runtime-stress] archived session but could not remove source $SESSION_HOME" \
      >&2
    return 1
  fi
}

remove_build_root() {
  if [[ -z "$BUILD_ROOT" ]]; then
    return 0
  fi
  case "$BUILD_ROOT" in
    /tmp/ios-use-playcover-runtime-stress-build.*|\
    /private/tmp/ios-use-playcover-runtime-stress-build.*) ;;
    *)
      echo \
        "[playcover-runtime-stress] refusing unexpected build root: $BUILD_ROOT" \
        >&2
      return 1
      ;;
  esac
  if [[ -L "$BUILD_ROOT" || ( -e "$BUILD_ROOT" && ! -d "$BUILD_ROOT" ) ]]; then
    echo \
      "[playcover-runtime-stress] refusing unsafe build root: $BUILD_ROOT" \
      >&2
    return 1
  fi
  if [[ -d "$BUILD_ROOT" ]] &&
      ! /bin/rm -rf -- "$BUILD_ROOT"; then
    echo \
      "[playcover-runtime-stress] could not remove build root: $BUILD_ROOT" \
      >&2
    return 1
  fi
  BUILD_ROOT=""
  return 0
}

cleanup() {
  local exit_code=$?
  local cleanup_end_git_head=""
  local cleanup_repository_status=""
  trap - EXIT
  set +e
  if [[ -d "$SESSION_HOME" && -x "$CLI" ]]; then
    IOS_USE_HOME="$SESSION_HOME" "$CLI" stop \
      >"$RUN_DIR/cleanup-stop.stdout" \
      2>"$RUN_DIR/cleanup-stop.stderr" || true
  fi
  if [[ -n "$START_GIT_HEAD" ]]; then
    if ! cleanup_end_git_head="$(
      git -C "$ROOT_DIR" rev-parse --verify HEAD 2>/dev/null
    )"; then
      GATE_FAILURE="${GATE_FAILURE:+$GATE_FAILURE; }could not resolve checkout HEAD at gate exit"
      exit_code=1
    elif [[ "$cleanup_end_git_head" != "$START_GIT_HEAD" ]]; then
      GATE_FAILURE="${GATE_FAILURE:+$GATE_FAILURE; }checkout HEAD changed during the gate"
      exit_code=1
    fi
    if ! cleanup_repository_status="$(repository_status 2>/dev/null)"; then
      GATE_FAILURE="${GATE_FAILURE:+$GATE_FAILURE; }could not inspect checkout status at gate exit"
      exit_code=1
    elif [[ -n "$cleanup_repository_status" ]]; then
      printf '%s\n' "$cleanup_repository_status" >&2
      GATE_FAILURE="${GATE_FAILURE:+$GATE_FAILURE; }checkout was not clean at gate exit"
      exit_code=1
    fi
  fi
  if [[ "$ATTESTATION_WRITTEN" != "1" ]] &&
      command -v jq >/dev/null 2>&1; then
    write_attestation \
      "fail" \
      "${GATE_FAILURE:-gate exited with status $exit_code}" ||
      exit_code=1
  fi
  if [[ -d "$SESSION_HOME" ]]; then
    archive_and_remove_session_home || exit_code=1
  fi
  remove_build_root || exit_code=1
  if [[ "$GATE_PASSED" != "1" || "$exit_code" -ne 0 ]]; then
    echo \
      "[playcover-runtime-stress] Evidence retained for the failed gate." \
      >&2
  fi
  exit "$exit_code"
}

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  config_fail "Apple-silicon macOS is required"
fi
for required in git jq mktemp notifyutil plutil shasum strip swift xcrun; do
  command -v "$required" >/dev/null 2>&1 ||
    config_fail "$required is required"
done
if [[ "${IOS_USE_PLAYCOVER_FIXTURE_APP+x}" == "x" ]]; then
  config_fail \
    "IOS_USE_PLAYCOVER_FIXTURE_APP is forbidden; this gate builds the default fixture"
fi
if [[
  "${IOS_USE_FIXTURE_CONFIGURATION+x}" == "x" ||
  "${IOS_USE_FIXTURE_SDK+x}" == "x"
]]; then
  config_fail \
    "fixture configuration/SDK overrides are forbidden; this gate builds Release-iphoneos"
fi
if [[ ! -f "$PROBE_SOURCE" ]]; then
  config_fail "Runtime socket protocol probe is unavailable"
fi
assert_initial_repository_state

mkdir -p "$EVIDENCE_PARENT" ||
  config_fail "could not create the evidence parent"
RUN_DIR="$(
  mktemp -d "$EVIDENCE_PARENT/run.XXXXXX"
)" || config_fail "could not create an exclusive evidence directory"
if [[ ! -d "$RUN_DIR" || -L "$RUN_DIR" ]]; then
  config_fail "exclusive evidence directory is unavailable"
fi
/bin/chmod 700 "$RUN_DIR" ||
  config_fail "could not make the evidence directory owner-only"
RUN_ID="$(basename "$RUN_DIR")"
ARCHIVED_SESSION_HOME="$RUN_DIR/session-home"
MANIFEST="$RUN_DIR/manifest.tsv"
CLEAN_CYCLE_INDEX="$RUN_DIR/clean-cycle-index.tsv"
OBSERVATIONS="$RUN_DIR/observations.jsonl"
ATTESTATION="$RUN_DIR/attestation.json"
if [[ -e "$ATTESTATION" || -L "$ATTESTATION" ]]; then
  config_fail "exclusive evidence directory already contains attestation.json"
fi
printf 'schema\tcase\tcommand\tstdout\tstderr\n' >"$MANIFEST"
printf 'cycle\tsessionIdentifier\trunnerPid\tgeneration\n' \
  >"$CLEAN_CYCLE_INDEX"
: >"$OBSERVATIONS"
printf '%s\n' "$START_GIT_HEAD" >"$RUN_DIR/git-head"
trap cleanup EXIT

BUILD_ROOT="$(
  mktemp -d /tmp/ios-use-playcover-runtime-stress-build.XXXXXX
)" || config_fail "could not create an isolated build root"
case "$BUILD_ROOT" in
  /tmp/ios-use-playcover-runtime-stress-build.*|\
  /private/tmp/ios-use-playcover-runtime-stress-build.*) ;;
  *)
    config_fail "isolated build root has an unexpected path"
    ;;
esac
if [[ ! -d "$BUILD_ROOT" || -L "$BUILD_ROOT" ]]; then
  config_fail "isolated build root is unavailable"
fi
/bin/chmod 700 "$BUILD_ROOT" ||
  config_fail "could not make the isolated build root owner-only"
CLI_SCRATCH_PATH="$BUILD_ROOT/swiftpm"
FIXTURE_DERIVED_DATA="$BUILD_ROOT/fixture-derived"
CLI="$BUILD_ROOT/ios-use"
FIXTURE_APP="$FIXTURE_DERIVED_DATA/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"

echo \
  "[playcover-runtime-stress] Building and analyzing the Runtime from checkout $START_GIT_HEAD..." \
  >&2
bash "$ROOT_DIR/scripts/build_playcover_runtime.sh" \
  --replace \
  --analyze \
  >"$RUN_DIR/build-runtime.stdout" \
  2>"$RUN_DIR/build-runtime.stderr" ||
  fail_gate "Runtime fresh build and analysis"
isolated_runtime_parent="$BUILD_ROOT/.ios-use/playcover"
isolated_runtime_framework="$isolated_runtime_parent/IOSUsePlayRuntime.framework"
if ! /bin/mkdir -p "$isolated_runtime_parent" ||
    ! /usr/bin/ditto \
      "$BUILT_RUNTIME_FRAMEWORK" \
      "$isolated_runtime_framework"; then
  fail_gate "could not install the fresh Runtime beside the isolated CLI"
fi
RUNTIME_EXECUTABLE="$isolated_runtime_framework/IOSUsePlayRuntime"

echo \
  "[playcover-runtime-stress] Building the CLI in an isolated SwiftPM scratch directory..." \
  >&2
if ! {
  swift build \
    --package-path "$ROOT_DIR/swift-cli" \
    --scratch-path "$CLI_SCRATCH_PATH" \
    -c release
  cli_bin_path="$(
    swift build \
      --package-path "$ROOT_DIR/swift-cli" \
      --scratch-path "$CLI_SCRATCH_PATH" \
      -c release \
      --show-bin-path
  )"
  /bin/cp "$cli_bin_path/ios-use-swift" "$CLI"
  /usr/bin/strip "$CLI"
  /bin/chmod 700 "$CLI"
} >"$RUN_DIR/build-cli.stdout" 2>"$RUN_DIR/build-cli.stderr"; then
  fail_gate "CLI fresh build"
fi

echo \
  "[playcover-runtime-stress] Building the default fixture in isolated DerivedData..." \
  >&2
bash "$ROOT_DIR/playcover-fixtures/build.sh" \
  --configuration Release \
  --sdk iphoneos \
  --derived-data-path "$FIXTURE_DERIVED_DATA" \
  >"$RUN_DIR/build-fixture.stdout" \
  2>"$RUN_DIR/build-fixture.stderr" ||
  fail_gate "default fixture fresh build"

if [[ ! -x "$CLI" ]]; then
  fail_gate "fresh workspace CLI is not executable"
fi
if [[ ! -x "$RUNTIME_EXECUTABLE" ]]; then
  fail_gate "fresh Runtime executable is unavailable"
fi
if [[ ! -d "$FIXTURE_APP" || ! -f "$FIXTURE_APP/Info.plist" ]]; then
  fail_gate "fresh default fixture App is unavailable"
fi
fixture_executable_name="$(
  plutil -extract CFBundleExecutable raw -o - \
    -- "$FIXTURE_APP/Info.plist"
)" || fail_gate "default fixture has no CFBundleExecutable"
case "$fixture_executable_name" in
  ""|.|..|*/*)
    fail_gate "default fixture has an invalid CFBundleExecutable"
    ;;
esac
FIXTURE_EXECUTABLE="$FIXTURE_APP/$fixture_executable_name"
if [[ ! -x "$FIXTURE_EXECUTABLE" ]]; then
  fail_gate "fresh default fixture executable is unavailable"
fi

CLI_SHA256="$(sha256_file "$CLI")" ||
  fail_gate "could not hash the fresh CLI"
RUNTIME_EXECUTABLE_SHA256="$(sha256_file "$RUNTIME_EXECUTABLE")" ||
  fail_gate "could not hash the fresh Runtime executable"
FIXTURE_EXECUTABLE_SHA256="$(sha256_file "$FIXTURE_EXECUTABLE")" ||
  fail_gate "could not hash the fresh fixture executable"
FIXTURE_INFO_PLIST_SHA256="$(sha256_file "$FIXTURE_APP/Info.plist")" ||
  fail_gate "could not hash the fresh fixture Info.plist"
FIXTURE_APP_TREE_SHA256="$(sha256_tree "$FIXTURE_APP")" ||
  fail_gate "could not hash the complete fresh fixture App"
PROBE_SOURCE_SHA256="$(sha256_file "$PROBE_SOURCE")" ||
  fail_gate "could not hash the Runtime socket probe source"

SESSION_HOME="$(mktemp -d /tmp/iups.XXXXXX)"
if [[
  "$SESSION_HOME" != /tmp/iups.* ||
  ! -d "$SESSION_HOME" ||
  -L "$SESSION_HOME"
]]; then
  config_fail "could not create a safe isolated IOS_USE_HOME"
fi
CANONICAL_SESSION_HOME="$(cd "$SESSION_HOME" && pwd -P)"
printf '%s\n' "$SESSION_HOME" >"$RUN_DIR/session-home-origin"

record_command() {
  local case_name="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3
  local command_text=""
  local argument
  for argument in "$@"; do
    local quoted
    printf -v quoted '%q' "$argument"
    command_text+="${command_text:+ }$quoted"
  done
  printf '1\t%s\t%s\t%s\t%s\n' \
    "$case_name" \
    "$command_text" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
}

run_cli() {
  local case_name="$1"
  shift
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  record_command \
    "$case_name" \
    "$stdout_file" \
    "$stderr_file" \
    "$CLI" "$@"
  echo "[playcover-runtime-stress] RUN $case_name" >&2
  if ! IOS_USE_HOME="$SESSION_HOME" "$CLI" "$@" \
      >"$stdout_file" 2>"$stderr_file"; then
    fail_gate "$case_name"
  fi
}

is_healthy_status() {
  local case_name="$1"
  jq -e '
      .data.driver.status == "healthy" and
      (.data.driver.runnerPid | type) == "number" and
      .data.driver.runnerPid > 1 and
      (.data.driver.sessionIdentifier | type) == "string" and
      (.data.driver.sessionIdentifier |
        test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")) and
      (.data.driver.macGenerationKey | type) == "string" and
      (.data.driver.macGenerationKey |
        test("^[0-9a-f]{64}$")) and
      .data.driver.runtime.status == "healthy" and
      .data.driver.runtime.identityVerified == true and
      .data.driver.bundleId == "com.iosuse.playfixture.stablev1" and
      .data.driver.runtime.logicalWidth == 430 and
      .data.driver.runtime.logicalHeight == 932 and
      .data.driver.runtime.nativeWidth == 1290 and
      .data.driver.runtime.nativeHeight == 2796 and
      .data.driver.runtime.scale == 3 and
      .data.driver.runtime.host.opaque == true and
      (.data.driver.runtime.diagnostics.runtime.window
        .safeAreaCompatibility as $safeArea |
        $safeArea.stage == "ready" and
        $safeArea.safeAreaCompatibilityReady == true and
        $safeArea.safeAreaReady == true and
        $safeArea.deviceContractReady == true and
        $safeArea.windowSafeArea ==
          {"top":59,"left":0,"bottom":34,"right":0} and
        $safeArea.expectedWindowSafeArea ==
          {"top":59,"left":0,"bottom":34,"right":0})
    ' "$RUN_DIR/${case_name}.stdout" >/dev/null
}

assert_healthy_status() {
  local case_name="$1"
  if ! is_healthy_status "$case_name"; then
    fail_gate "$case_name did not prove an exact healthy fixture session"
  fi
}

run_healthy_status_with_retry() {
  local case_prefix="$1"
  local attempt
  local attempt_case
  HEALTHY_STATUS_CASE=""
  for attempt in $(seq 1 50); do
    printf -v attempt_case '%s_%02d' "$case_prefix" "$attempt"
    run_cli "$attempt_case" status --json
    if is_healthy_status "$attempt_case"; then
      HEALTHY_STATUS_CASE="$attempt_case"
      return 0
    fi
    sleep 0.1
  done
  fail_gate \
    "$case_prefix did not converge to an exact healthy fixture session"
}

assert_full_status_diagnostics() {
  local case_name="$1"
  if ! jq -e '
      .data.driver.runtime.diagnostics.runtime as $runtime |
      ($runtime | has("implementation")) and
      ($runtime | has("playToolsCommit")) and
      ($runtime | has("configurationAttempts")) and
      ($runtime | has("device")) and
      ($runtime | has("rendering")) and
      ($runtime.window as $window |
        ($window | has("scenes")) and
        ($window | has("contentViewTree")) and
        ($window | has("allWindows")) and
        ($window | has("screenFrame")) and
        ($window | has("screenVisibleFrame")) and
        ($window | has("screenDisplayID")) and
        ($window | has("screenIsMain")) and
        ($window | has("nativeAlert")) and
        ($window | has("bootstrapNativeAlert")) and
        ($window | has("safeAreaCompatibility")) and
        ($window | has("resizeEdges")) and
        ($window | has("styleMask")) and
        ($window | has("mouseMonitorReady")) and
        ($window | has("lastMouseDelivery")) and
        ($window | has("mouseDeliveryCount")))
    ' "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    fail_gate "$case_name omitted full status-only Runtime diagnostics"
  fi
}

assert_stopped() {
  local case_name="$1"
  if ! jq -e \
      '.data.driver.status == "notRunning"' \
      "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    fail_gate "$case_name did not prove that the session lock was cleared"
  fi
  if [[
    -e "$SESSION_HOME/state/driver.lock" ||
    -L "$SESSION_HOME/state/driver.lock"
  ]]; then
    fail_gate "$case_name left driver.lock behind"
  fi
}

assert_lock_matches_status() {
  local status_case="$1"
  local lock="$SESSION_HOME/state/driver.lock"
  if [[ ! -f "$lock" || -L "$lock" ]]; then
    fail_gate "$status_case has no private regular driver.lock"
  fi
  if [[ "$(stat -f '%Lp' "$lock")" != "600" ]]; then
    fail_gate "$status_case driver.lock is not owner-only"
  fi
  if ! jq -e \
      --arg rawHome "$SESSION_HOME" \
      --arg canonicalHome "$CANONICAL_SESSION_HOME" \
      --slurpfile status "$RUN_DIR/${status_case}.stdout" '
      . as $lock |
      $status[0].data.driver as $driver |
      $lock.deviceType == "mac" and
      $lock.startMode == "mac" and
      $lock.bundleId == "com.iosuse.playfixture.stablev1" and
      $lock.bundleId == $driver.bundleId and
      $lock.sessionIdentifier == $driver.sessionIdentifier and
      ($lock.sessionIdentifier |
        test("^[0-9A-Fa-f-]{36}$")) and
      $lock.runnerPid == $driver.runnerPid and
      $lock.runnerPid > 1 and
      $lock.macGenerationKey ==
        $driver.macGenerationKey and
      ($lock.macGenerationKey |
        test("^[0-9a-f]{64}$")) and
      $lock.macRuntimeSocketPath ==
        $driver.macRuntimeSocketPath and
      $lock.macAppPath == $driver.macAppPath and
      $lock.macExecutablePath ==
        $driver.macExecutablePath and
      (
        ($lock.macAppPath |
          startswith($rawHome + "/cache/mac/prepared/")) or
        ($lock.macAppPath |
          startswith($canonicalHome + "/cache/mac/prepared/"))
      ) and
      ($lock.macExecutablePath |
        startswith($lock.macAppPath + "/")) and
      (
        ($lock.macRuntimeSocketPath |
          startswith($rawHome + "/mac/run/s-")) or
        ($lock.macRuntimeSocketPath |
          startswith($canonicalHome + "/mac/run/s-"))
      ) and
      ($lock.macRuntimeSocketPath |
        endswith(".sock"))
    ' "$lock" >/dev/null; then
    fail_gate "$status_case driver.lock does not match the live exact identity"
  fi
}

assert_stdio_log() {
  local status_case="$1"
  local status_file="$RUN_DIR/${status_case}.stdout"
  local session_identifier
  local lower_session_identifier
  local log_path
  local expected_path
  local log_device
  local log_inode
  local markers_observed=0
  session_identifier="$(
    jq -er '.data.driver.sessionIdentifier' "$status_file"
  )" || fail_gate "$status_case has no exact session identifier"
  log_path="$(
    jq -er '.data.driver.macLogPath' "$status_file"
  )" || fail_gate "$status_case has no per-session stdio log"
  lower_session_identifier="$(
    printf '%s' "$session_identifier" |
      /usr/bin/tr '[:upper:]' '[:lower:]'
  )"
  expected_path="$CANONICAL_SESSION_HOME/mac/logs/stdio-$lower_session_identifier.log"
  if [[
    "$log_path" != "$expected_path" ||
    ! -f "$log_path" ||
    -L "$log_path" ||
    "$(/usr/bin/stat -f '%u' "$log_path")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$log_path")" != "600" ||
    "$(/usr/bin/stat -f '%l' "$log_path")" != "1"
  ]]; then
    fail_gate "$status_case has no exact owner-only stdio log"
  fi
  log_device="$(/usr/bin/stat -f '%d' "$log_path")"
  log_inode="$(/usr/bin/stat -f '%i' "$log_path")"
  if ! jq -e \
      --arg path "$log_path" \
      --arg device "$log_device" \
      --arg inode "$log_inode" '
        .data.driver.macLogPath == $path and
        .data.driver.runtime.stdio.status == "redirected" and
        .data.driver.runtime.stdio.path == $path and
        .data.driver.runtime.stdio.device == $device and
        .data.driver.runtime.stdio.inode == $inode and
        .data.driver.runtime.stdio.failureStage == null and
        .data.driver.runtime.stdio.errorNumber == null
      ' "$status_file" >/dev/null; then
    fail_gate "$status_case omitted exact Runtime stdio identity"
  fi
  for _ in $(seq 1 100); do
    if rg -Fq \
        "[ios-use-play-fixture] stdout $session_identifier" \
        "$log_path" &&
      rg -Fq \
        "[ios-use-play-fixture] stderr $session_identifier" \
        "$log_path"; then
      markers_observed=1
      break
    fi
    sleep 0.05
  done
  if [[ "$markers_observed" != "1" ]]; then
    fail_gate "$status_case stdio log omitted fixture markers"
  fi
  printf '%s\n' "$log_path"
}

assert_expected_generation() {
  local case_name="$1"
  local generation="$2"
  if ! jq -e \
      --arg generation "$generation" \
      '.data.driver.macGenerationKey == $generation' \
      "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    fail_gate "$case_name did not reuse generation $generation"
  fi
}

assert_bare_start_reused() {
  local case_name="$1"
  local generation="$2"
  if ! /usr/bin/grep -Fqx \
      "Mac generation reused: $generation" \
      "$RUN_DIR/${case_name}.stdout"; then
    fail_gate "$case_name did not report exact bare generation reuse"
  fi
}

assert_live_runtime_socket() {
  local case_name="$1"
  local runtime_socket
  runtime_socket="$(
    jq -er '.data.driver.macRuntimeSocketPath' \
      "$RUN_DIR/${case_name}.stdout"
  )"
  case "$runtime_socket" in
    "$SESSION_HOME"/mac/run/s-*.sock) ;;
    "$CANONICAL_SESSION_HOME"/mac/run/s-*.sock) ;;
    *)
      fail_gate \
        "$case_name Runtime socket escapes the isolated run directory"
      ;;
  esac
  if [[
    ! -S "$runtime_socket" ||
    -L "$runtime_socket" ||
    "$(stat -f '%u' "$runtime_socket")" != "$(id -u)" ||
    "$(stat -f '%Lp' "$runtime_socket")" != "600"
  ]]; then
    fail_gate "$case_name Runtime socket is not the owner-only live endpoint"
  fi
}

assert_same_live_session() {
  local before_case="$1"
  local after_case="$2"
  if ! jq -e \
      --slurpfile before "$RUN_DIR/${before_case}.stdout" '
      .data.driver as $after |
      $before[0].data.driver as $prior |
      $after.sessionIdentifier == $prior.sessionIdentifier and
      $after.runnerPid == $prior.runnerPid and
      $after.macGenerationKey ==
        $prior.macGenerationKey and
      $after.macAppPath == $prior.macAppPath and
      $after.macExecutablePath ==
        $prior.macExecutablePath and
      $after.macRuntimeSocketPath ==
        $prior.macRuntimeSocketPath
    ' "$RUN_DIR/${after_case}.stdout" >/dev/null; then
    fail_gate "$after_case no longer describes $before_case's live session"
  fi
}

assert_clean_session_stopped() {
  local case_name="$1"
  local runner_pid="$2"
  local runtime_socket="$3"
  local attempt
  local pid_exited=0
  local socket_removed=0

  assert_stopped "$case_name"
  if [[ ! "$runner_pid" =~ ^[0-9]+$ || "$runner_pid" -le 1 ]]; then
    fail_gate "$case_name has an invalid recorded runner PID"
  fi
  case "$runtime_socket" in
    "$SESSION_HOME"/mac/run/s-*.sock) ;;
    "$CANONICAL_SESSION_HOME"/mac/run/s-*.sock) ;;
    *)
      fail_gate \
        "$case_name has an invalid recorded Runtime socket pathname"
      ;;
  esac

  for attempt in $(seq 1 50); do
    if ! /bin/kill -0 "$runner_pid" 2>/dev/null; then
      pid_exited=1
      break
    fi
    sleep 0.1
  done
  if [[ "$pid_exited" != "1" ]]; then
    fail_gate "$case_name left runner PID $runner_pid alive"
  fi

  for attempt in $(seq 1 50); do
    if [[ ! -e "$runtime_socket" && ! -L "$runtime_socket" ]]; then
      socket_removed=1
      break
    fi
    sleep 0.1
  done
  if [[ "$socket_removed" != "1" ]]; then
    fail_gate \
      "$case_name left Runtime socket pathname $runtime_socket behind"
  fi
  jq -cn \
    --arg case "$case_name" \
    --argjson runnerPid "$runner_pid" \
    --arg runtimeSocketPath "$runtime_socket" '
      {
        kind: "clean-stop",
        case: $case,
        runnerPid: $runnerPid,
        runtimeSocketPath: $runtimeSocketPath,
        driverLockAbsent: true,
        runnerPidAbsent: true,
        runtimeSocketAbsent: true
      }
    ' >>"$OBSERVATIONS"
}

assert_scene_two() {
  local case_name="$1"
  if ! jq -e '
      [
        .data.postDom.elements[] |
        select(
          .identifier == "fixture.scene.status" and
          .label == "Scene 2" and
          .value == "2"
        )
      ] | length == 1
    ' "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    fail_gate "$case_name did not prove Scene 2 in the fresh post-action DOM"
  fi
}

assert_scene_replace_visible() {
  local case_name="$1"
  if ! jq -e '
      [
        .data.postDom.elements[] |
        select(
          .identifier == "fixture.scene.replace" and
          .label == "Replace Scene Window" and
          .state.visible == true
        )
      ] | length == 1
    ' "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    fail_gate \
      "$case_name did not bring Replace Scene Window into the visible DOM"
  fi
}

run_cli protocol_start start --mac --app "$FIXTURE_APP"
run_cli protocol_status status --json
assert_healthy_status protocol_status
assert_lock_matches_status protocol_status
assert_live_runtime_socket protocol_status
protocol_generation_key="$(
  jq -er '.data.driver.macGenerationKey' \
    "$RUN_DIR/protocol_status.stdout"
)"
PROTOCOL_GENERATION_KEY="$protocol_generation_key"
protocol_pid="$(
  jq -er '.data.driver.runnerPid' \
    "$RUN_DIR/protocol_status.stdout"
)"
runtime_socket="$(
  jq -er '.data.driver.macRuntimeSocketPath' \
    "$RUN_DIR/protocol_status.stdout"
)"
protocol_session_identifier="$(
  jq -er '.data.driver.sessionIdentifier' \
    "$RUN_DIR/protocol_status.stdout"
)"
if [[ ! "$protocol_generation_key" =~ ^[0-9a-f]{64}$ ]]; then
  fail_gate "protocol start has no exact prepared generation"
fi
if ! /usr/bin/grep -Fqx \
    "Mac generation prepared: $protocol_generation_key" \
    "$RUN_DIR/protocol_start.stdout"; then
  fail_gate "protocol start did not explicitly prepare its generation"
fi
printf '%s\n' "$protocol_generation_key" >"$RUN_DIR/generation-key"

readiness_probe_stdout="$RUN_DIR/hello_readiness.stdout"
readiness_probe_stderr="$RUN_DIR/hello_readiness.stderr"
record_command \
  hello_readiness \
  "$readiness_probe_stdout" \
  "$readiness_probe_stderr" \
  xcrun swift \
  "$PROBE_SOURCE" \
  "$runtime_socket" \
  hello-readiness \
  "$protocol_session_identifier"
if ! xcrun swift \
    "$PROBE_SOURCE" \
    "$runtime_socket" \
    hello-readiness \
    "$protocol_session_identifier" \
    >"$readiness_probe_stdout" 2>"$readiness_probe_stderr"; then
  fail_gate "hello_readiness"
fi
if ! jq -e '
    .schemaVersion == 1 and
    .mode == "hello-readiness" and
    .runtimeListenerSurvived == true and
    .responseBytes > 0 and
    .readinessAppKitFieldCount == 27 and
    .statusOnlyAppKitFieldCount == 0
  ' "$readiness_probe_stdout" >/dev/null; then
  fail_gate "hello_readiness did not expose the minimal Runtime payload"
fi
run_cli hello_readiness_status status --json
assert_healthy_status hello_readiness_status
assert_full_status_diagnostics hello_readiness_status
assert_expected_generation \
  hello_readiness_status \
  "$protocol_generation_key"
assert_same_live_session protocol_status hello_readiness_status
assert_lock_matches_status hello_readiness_status
assert_live_runtime_socket hello_readiness_status
jq -c '
    {
      kind: "hello-readiness-shape",
      responseBytes,
      readinessAppKitFieldCount,
      statusOnlyAppKitFieldCount,
      fullStatusDiagnosticsVerified: true,
      runtimeListenerSurvived,
      postProbeSessionHealthy: true
    }
  ' "$readiness_probe_stdout" >>"$OBSERVATIONS"

for probe_mode in \
  oversized-frame \
  malformed-json \
  invalid-utf8 \
  zero-length \
  exact-limit-invalid-json \
  truncated-frame; do
  probe_case="${probe_mode//-/_}"
  probe_stdout="$RUN_DIR/${probe_case}.stdout"
  probe_stderr="$RUN_DIR/${probe_case}.stderr"
  case "$probe_mode" in
    oversized-frame|zero-length)
      expected_probe_error="invalid_frame"
      ;;
    malformed-json|invalid-utf8|exact-limit-invalid-json)
      expected_probe_error="invalid_json"
      ;;
    truncated-frame)
      expected_probe_error="connection_closed"
      ;;
    *)
      fail_gate "no expected protocol error for $probe_mode"
      ;;
  esac
  record_command \
    "$probe_case" \
    "$probe_stdout" \
    "$probe_stderr" \
    xcrun swift \
    "$ROOT_DIR/playcover-fixtures/runtime_socket_probe.swift" \
    "$runtime_socket" \
    "$probe_mode"
  if ! xcrun swift \
      "$ROOT_DIR/playcover-fixtures/runtime_socket_probe.swift" \
      "$runtime_socket" \
      "$probe_mode" \
      >"$probe_stdout" 2>"$probe_stderr"; then
    fail_gate "$probe_case"
  fi
  if ! jq -e \
      --arg mode "$probe_mode" \
      --arg expectedError "$expected_probe_error" '
      .schemaVersion == 1 and
      .mode == $mode and
      .runtimeListenerSurvived == true and
      .runtimeErrorCode == $expectedError
    ' "$probe_stdout" >/dev/null; then
    fail_gate "$probe_case did not return the exact bounded protocol error"
  fi
  run_cli "${probe_case}_status" status --json
  assert_healthy_status "${probe_case}_status"
  assert_expected_generation \
    "${probe_case}_status" \
    "$protocol_generation_key"
  assert_lock_matches_status "${probe_case}_status"
  jq -cn \
    --arg mode "$probe_mode" \
    --arg runtimeErrorCode "$expected_probe_error" '
      {
        kind: "protocol-boundary",
        mode: $mode,
        runtimeErrorCode: $runtimeErrorCode,
        runtimeListenerSurvived: true,
        postProbeSessionHealthy: true
      }
    ' >>"$OBSERVATIONS"
done
run_cli protocol_stop stop
run_cli protocol_stopped status --json
assert_clean_session_stopped \
  protocol_stopped \
  "$protocol_pid" \
  "$runtime_socket"

echo \
  "[playcover-runtime-stress] Running $CLEAN_CYCLE_COUNT clean bare lifecycle cycles..." \
  >&2
for cycle in $(seq 1 "$CLEAN_CYCLE_COUNT"); do
  printf -v cycle_name 'clean_cycle_%02d' "$cycle"
  run_cli "${cycle_name}_start" start --mac --reuse
  assert_bare_start_reused \
    "${cycle_name}_start" \
    "$protocol_generation_key"

  run_cli "${cycle_name}_status" status --json
  assert_healthy_status "${cycle_name}_status"
  assert_expected_generation \
    "${cycle_name}_status" \
    "$protocol_generation_key"
  assert_lock_matches_status "${cycle_name}_status"
  assert_live_runtime_socket "${cycle_name}_status"
  cycle_session_identifier="$(
    jq -er '.data.driver.sessionIdentifier' \
      "$RUN_DIR/${cycle_name}_status.stdout"
  )"
  cycle_runner_pid="$(
    jq -er '.data.driver.runnerPid' \
      "$RUN_DIR/${cycle_name}_status.stdout"
  )"
  cycle_runtime_socket="$(
    jq -er '.data.driver.macRuntimeSocketPath' \
      "$RUN_DIR/${cycle_name}_status.stdout"
  )"
  if /usr/bin/awk -F '\t' \
      -v session="$cycle_session_identifier" '
      NR > 1 && $2 == session {
        found = 1
      }
      END {
        exit !found
      }
    ' "$CLEAN_CYCLE_INDEX"; then
    fail_gate "$cycle_name reused an earlier session identifier"
  fi
  jq -er --argjson cycle "$cycle" '
      [
        $cycle,
        .data.driver.sessionIdentifier,
        .data.driver.runnerPid,
        .data.driver.macGenerationKey
      ] |
      @tsv
    ' "$RUN_DIR/${cycle_name}_status.stdout" \
    >>"$CLEAN_CYCLE_INDEX" ||
    fail_gate "$cycle_name has incomplete lifecycle identity"

  if [[ "$cycle" -eq 1 ]]; then
    run_cli \
      "${cycle_name}_scene_scroll" \
      swipe --dir forth --distance 300 --dom --json
    assert_scene_replace_visible "${cycle_name}_scene_scroll"
    run_cli \
      "${cycle_name}_scene_replace" \
      tap "Replace Scene Window" --dom --json
    assert_scene_two "${cycle_name}_scene_replace"
    run_healthy_status_with_retry "${cycle_name}_post_tap_status"
    post_tap_status_case="$HEALTHY_STATUS_CASE"
    assert_healthy_status "$post_tap_status_case"
    assert_expected_generation \
      "$post_tap_status_case" \
      "$protocol_generation_key"
    assert_same_live_session \
      "${cycle_name}_status" \
      "$post_tap_status_case"
    assert_lock_matches_status "$post_tap_status_case"
    assert_live_runtime_socket "$post_tap_status_case"
  fi

  run_cli "${cycle_name}_stop" stop
  run_cli "${cycle_name}_stopped" status --json
  assert_clean_session_stopped \
    "${cycle_name}_stopped" \
    "$cycle_runner_pid" \
    "$cycle_runtime_socket"
done

if ! /usr/bin/awk -F '\t' \
    -v expected="$CLEAN_CYCLE_COUNT" \
    -v expectedGeneration="$protocol_generation_key" '
    NR == 1 {
      next
    }
    {
      if ($1 != rows + 1) invalid = 1
      if (length($2) != 36) invalid = 1
      if ($3 !~ /^[0-9]+$/) invalid = 1
      if ($3 <= 1) invalid = 1
      if ($4 != expectedGeneration) invalid = 1
      rows += 1
      sessions[$2] = 1
      generations[$4] = 1
    }
    END {
      if (invalid || rows != expected) {
        exit 1
      }
      sessionCount = 0
      for (session in sessions) {
        sessionCount += 1
      }
      generationCount = 0
      for (generation in generations) {
        generationCount += 1
      }
      if (sessionCount != expected || generationCount != 1) {
        exit 1
      }
    }
  ' "$CLEAN_CYCLE_INDEX"; then
  fail_gate \
    "clean bare lifecycle cycles did not bind unique sessions to one generation"
fi
run_cli endpoint_start start --mac --reuse
assert_bare_start_reused endpoint_start "$protocol_generation_key"
run_cli endpoint_status status --json
assert_healthy_status endpoint_status
assert_expected_generation endpoint_status "$protocol_generation_key"
assert_lock_matches_status endpoint_status
assert_live_runtime_socket endpoint_status
endpoint_pid="$(
  jq -er '.data.driver.runnerPid' \
    "$RUN_DIR/endpoint_status.stdout"
)"
endpoint_socket="$(
  jq -er '.data.driver.macRuntimeSocketPath' \
    "$RUN_DIR/endpoint_status.stdout"
)"
case "$endpoint_socket" in
  "$SESSION_HOME"/mac/run/s-*.sock) ;;
  "$CANONICAL_SESSION_HOME"/mac/run/s-*.sock) ;;
  *) fail_gate "endpoint-loss target escapes the isolated Runtime run directory" ;;
esac
if [[
  ! -S "$endpoint_socket" ||
  -L "$endpoint_socket" ||
  "$(stat -f '%u' "$endpoint_socket")" != "$(id -u)"
]]; then
  fail_gate "endpoint-loss target is not the exact owner socket"
fi
/bin/unlink "$endpoint_socket"
run_cli endpoint_unhealthy status --json
if ! jq -e \
    --argjson pid "$endpoint_pid" '
    .data.driver.status == "unhealthy" and
    .data.driver.runnerPid == $pid and
    .data.driver.runtime.status == "unhealthy" and
    .data.driver.runtime.identityVerified == false
  ' "$RUN_DIR/endpoint_unhealthy.stdout" >/dev/null; then
  fail_gate "Runtime endpoint loss was not classified as unhealthy"
fi
if ! /bin/kill -0 "$endpoint_pid" 2>/dev/null; then
  fail_gate "Runtime endpoint loss unexpectedly terminated the App"
fi
jq -cn \
  --argjson runnerPid "$endpoint_pid" \
  --arg runtimeSocketPath "$endpoint_socket" '
    {
      kind: "endpoint-loss",
      runnerPid: $runnerPid,
      runtimeSocketPath: $runtimeSocketPath,
      driverStatus: "unhealthy",
      runtimeStatus: "unhealthy",
      runtimeIdentityVerified: false,
      appRemainedAlive: true
    }
  ' >>"$OBSERVATIONS"
run_cli endpoint_stop stop
run_cli endpoint_stopped status --json
assert_clean_session_stopped \
  endpoint_stopped \
  "$endpoint_pid" \
  "$endpoint_socket"

run_cli crash_start start --mac --reuse --log
assert_bare_start_reused crash_start "$protocol_generation_key"
run_cli crash_status status --json
assert_healthy_status crash_status
assert_expected_generation crash_status "$protocol_generation_key"
assert_lock_matches_status crash_status
assert_live_runtime_socket crash_status
crash_stdio_log="$(assert_stdio_log crash_status)"
crash_stdio_log_identity="$(
  /usr/bin/stat -f '%d:%i:%u:%Lp:%l' "$crash_stdio_log"
)"
crash_pid="$(
  jq -er '.data.driver.runnerPid' \
    "$RUN_DIR/crash_status.stdout"
)"
crash_session_identifier="$(
  jq -er '.data.driver.sessionIdentifier' \
    "$RUN_DIR/crash_status.stdout"
)"
crash_socket="$(
  jq -er '.data.driver.macRuntimeSocketPath' \
    "$RUN_DIR/crash_status.stdout"
)"
if [[
  ! "$crash_pid" =~ ^[0-9]+$ ||
  "$crash_pid" -le 1 ||
  "$crash_pid" != "$(
    jq -er '.runnerPid' "$SESSION_HOME/state/driver.lock"
  )"
]]; then
  fail_gate "App-crash PID is not bound to the exact driver.lock"
fi
if [[
  ! -S "$crash_socket" ||
  -L "$crash_socket" ||
  "$(stat -f '%u' "$crash_socket")" != "$(id -u)"
]]; then
  fail_gate "App-crash target has no exact owner Runtime socket"
fi
crash_socket_identity="$(
  stat -f '%d:%i:%u:%Lp' "$crash_socket"
)"
printf 'path=%s\nidentity=%s\n' \
  "$crash_socket" \
  "$crash_socket_identity" \
  >"$RUN_DIR/crash-residue-before.txt"
crash_notification_name="com.iosuse.playfixture.self-sigkill.$crash_session_identifier"
if ! /usr/bin/notifyutil -p "$crash_notification_name"; then
  fail_gate "could not request the fixture-owned self-SIGKILL"
fi
crash_observed=0
for attempt in $(seq 1 100); do
  run_cli crash_stale status --json
  if jq -e '
      .data.driver.status == "stale" and
      .data.driver.runtime.status == "stale" and
      .data.driver.runtime.identityVerified == false and
      (.data.driver.runtime.error |
        contains("recorded App process is not running"))
    ' "$RUN_DIR/crash_stale.stdout" >/dev/null; then
    crash_observed=1
    break
  fi
  sleep 0.05
done
if [[ "$crash_observed" != "1" ]]; then
  fail_gate "App crash was not classified as an exact stale session"
fi
run_cli crash_stop stop
run_cli crash_stopped status --json
assert_stopped crash_stopped
if /bin/kill -0 "$crash_pid" 2>/dev/null; then
  fail_gate "App-crash stale cleanup left PID $crash_pid alive"
fi
if [[ ! -f "$crash_stdio_log" || -L "$crash_stdio_log" ]] ||
  [[
    "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l' "$crash_stdio_log")" != "$crash_stdio_log_identity"
  ]]; then
  fail_gate "App SIGKILL/stop did not retain the exact stdio log"
fi
if [[
  ! -S "$crash_socket" ||
  -L "$crash_socket" ||
  "$(stat -f '%d:%i:%u:%Lp' "$crash_socket")" != "$crash_socket_identity"
]]; then
  fail_gate \
    "App SIGKILL did not preserve the exact Runtime socket residue"
fi
crash_socket_identity_after_stop="$(
  stat -f '%d:%i:%u:%Lp' "$crash_socket"
)"
printf 'path=%s\nidentity=%s\n' \
  "$crash_socket" \
  "$crash_socket_identity_after_stop" \
  >"$RUN_DIR/crash-residue-after-stop.txt"
jq -cn \
  --argjson runnerPid "$crash_pid" \
  --arg runtimeSocketPath "$crash_socket" \
  --arg stdioLogPath "$crash_stdio_log" \
  --arg stdioLogIdentity "$crash_stdio_log_identity" \
  --arg identityBefore "$crash_socket_identity" \
  --arg identityAfterStop "$crash_socket_identity_after_stop" '
    {
      kind: "app-sigkill",
      trigger: "fixture-darwin-notification",
      selfTriggered: true,
      runnerPid: $runnerPid,
      runtimeSocketPath: $runtimeSocketPath,
      stdioLogPath: $stdioLogPath,
      stdioLogIdentity: $stdioLogIdentity,
      stdioMarkersObservedWhileAlive: true,
      stdioLogRetainedAfterCrashAndStop: true,
      staleSessionObserved: true,
      driverLockAbsentAfterStop: true,
      runnerPidAbsentAfterStop: true,
      residueIdentityBefore: $identityBefore,
      residueIdentityAfterStop: $identityAfterStop,
      exactResiduePreserved: (
        $identityBefore == $identityAfterStop
      )
    }
  ' >>"$OBSERVATIONS"

run_cli crash_recovery_start start --mac --reuse
assert_bare_start_reused \
  crash_recovery_start \
  "$protocol_generation_key"
run_cli crash_recovery_status status --json
assert_healthy_status crash_recovery_status
assert_expected_generation \
  crash_recovery_status \
  "$protocol_generation_key"
assert_lock_matches_status crash_recovery_status
assert_live_runtime_socket crash_recovery_status
crash_recovery_pid="$(
  jq -er '.data.driver.runnerPid' \
    "$RUN_DIR/crash_recovery_status.stdout"
)"
crash_recovery_socket="$(
  jq -er '.data.driver.macRuntimeSocketPath' \
    "$RUN_DIR/crash_recovery_status.stdout"
)"
if [[ "$crash_recovery_socket" == "$crash_socket" ]]; then
  fail_gate "App-crash recovery reused the stale Runtime socket pathname"
fi
run_cli crash_recovery_stop stop
run_cli crash_recovery_stopped status --json
assert_clean_session_stopped \
  crash_recovery_stopped \
  "$crash_recovery_pid" \
  "$crash_recovery_socket"
if [[
  ! -S "$crash_socket" ||
  -L "$crash_socket" ||
  "$(stat -f '%d:%i:%u:%Lp' "$crash_socket")" != "$crash_socket_identity"
]]; then
  fail_gate \
    "a later random session mutated the preserved crash residue"
fi
crash_socket_identity_after_recovery="$(
  stat -f '%d:%i:%u:%Lp' "$crash_socket"
)"
printf 'path=%s\nidentity=%s\n' \
  "$crash_socket" \
  "$crash_socket_identity_after_recovery" \
  >"$RUN_DIR/crash-residue-after-recovery.txt"
jq -cn \
  --arg staleRuntimeSocketPath "$crash_socket" \
  --arg freshRuntimeSocketPath "$crash_recovery_socket" \
  --arg identityBefore "$crash_socket_identity" \
  --arg identityAfterRecovery "$crash_socket_identity_after_recovery" '
    {
      kind: "app-crash-recovery",
      staleRuntimeSocketPath: $staleRuntimeSocketPath,
      freshRuntimeSocketPath: $freshRuntimeSocketPath,
      freshPathDifferent: (
        $staleRuntimeSocketPath != $freshRuntimeSocketPath
      ),
      freshSessionStoppedCleanly: true,
      staleResidueIdentityBefore: $identityBefore,
      staleResidueIdentityAfterRecovery: $identityAfterRecovery,
      staleResidueUnchanged: (
        $identityBefore == $identityAfterRecovery
      )
    }
  ' >>"$OBSERVATIONS"

assert_built_inputs_unchanged
if ! archive_and_remove_session_home; then
  fail_gate "could not archive the isolated session home"
fi
if ! remove_build_root; then
  fail_gate "could not remove the isolated build root"
fi
assert_repository_unchanged
if ! write_attestation "pass" ""; then
  fail_gate "could not validate and publish the pass attestation"
fi
GATE_PASSED=1
trap - EXIT
echo \
  "[playcover-runtime-stress] PASS: minimal hello readiness, bounded frames, endpoint loss, clean bare lifecycles, semantic Runtime tap, and App-crash recovery with preserved residue" \
  >&2
