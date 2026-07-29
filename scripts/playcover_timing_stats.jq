def fail($message):
  error("playcover timing stats: \($message)");

def phase_names:
  [
    "inspect",
    "verify",
    "launch",
    "alias",
    "openDispatch",
    "exactOwnership",
    "runtimeTransportPing",
    "readyGeometry",
    "total"
  ];

def has_exact_keys($expected):
  (type == "object")
  and ((keys | sort) == ($expected | sort));

def is_sha256:
  (type == "string") and test("^[0-9a-f]{64}$");

def is_finite_nonnegative:
  if type != "number" then
    false
  else
    ((isnan or isinfinite) | not) and (. >= 0)
  end;

def validate_sample:
  . as $sample
  | if ($sample | has_exact_keys(
      ["case", "generationKey", "fixtureAppTreeSHA256", "phases"]
    ) | not) then
      fail("sample fields must be exact")
    else
      $sample
    end
  | if (
      (.case | type) != "string"
      or (.case | test("^clean_cycle_[0-9]{2}_start$") | not)
    ) then
      fail("sample case is invalid")
    else
      .
    end
  | if (.generationKey | is_sha256 | not) then
      fail("sample generationKey must be a lowercase SHA-256")
    else
      .
    end
  | if (.fixtureAppTreeSHA256 | is_sha256 | not) then
      fail("sample fixtureAppTreeSHA256 must be a lowercase SHA-256")
    else
      .
    end
  | if (.phases | has_exact_keys(phase_names) | not) then
      fail("sample phase fields must be exact")
    else
      .
    end
  | . as $validated
  | if (
      [
        phase_names[] as $phase
        | if $phase == "runtimeTransportPing" then
            (
              $validated.phases[$phase] == null
              or ($validated.phases[$phase] | is_finite_nonnegative)
            )
          else
            ($validated.phases[$phase] | is_finite_nonnegative)
          end
      ]
      | all
      | not
    ) then
      fail(
        "phase values must be finite nonnegative numbers; "
        + "only runtimeTransportPing may be null"
      )
    else
      $validated
    end
  | if (
      .phases.runtimeTransportPing != null
      and (
        .phases.runtimeTransportPing
        > .phases.exactOwnership
      )
    ) then
      fail(
        "runtimeTransportPing must not exceed its "
        + "exactOwnership gross interval"
      )
    else
      .
    end;

def validate_samples:
  if type != "array" then
    fail("build input must be a slurped sample array")
  elif length < 5 then
    fail("at least five samples are required")
  else
    [.[] | validate_sample]
  end
  | . as $samples
  | ($samples | length) as $sample_count
  | if ([$samples[].case] | unique | length) != $sample_count then
      fail("sample cases must be unique")
    else
      $samples
    end
  | if ([$samples[].generationKey] | unique | length) != 1 then
      fail("all samples must use one generationKey")
    else
      .
    end
  | if ([$samples[].fixtureAppTreeSHA256] | unique | length) != 1 then
      fail("all samples must use one fixtureAppTreeSHA256")
    else
      .
    end;

def median:
  sort as $sorted
  | ($sorted | length) as $count
  | if $count == 0 then
      null
    else
      ($count / 2 | floor) as $middle
      | if ($count % 2) == 1 then
          $sorted[$middle]
        else
          (
            $sorted[$middle - 1]
            + (($sorted[$middle] - $sorted[$middle - 1]) / 2)
          )
        end
    end;

def phase_summary($samples; $phase):
  [$samples[].phases[$phase] | select(. != null)] as $observed
  | ($observed | length) as $observed_count
  | (($samples | length) - $observed_count) as $skipped_count
  | if $observed_count == 0 then
      {
        observedSampleCount: 0,
        skippedSampleCount: $skipped_count,
        medianMs: null,
        rawMadMs: null,
        normalizedMadMs: null,
        relativeMadPercent: null
      }
    else
      ($observed | median) as $median
      | ([$observed[] | (. - $median) | abs] | median) as $raw_mad
      | ($raw_mad * 1.4826) as $normalized_mad
      | (
          if $median == 0 then
            null
          else
            ($raw_mad / $median) * 100
          end
        ) as $relative_mad
      | if (
          ($median | is_finite_nonnegative | not)
          or ($raw_mad | is_finite_nonnegative | not)
          or ($normalized_mad | is_finite_nonnegative | not)
          or (
            $relative_mad != null
            and ($relative_mad | is_finite_nonnegative | not)
          )
        ) then
          fail("derived phase statistics must be finite")
        else
          {
            observedSampleCount: $observed_count,
            skippedSampleCount: $skipped_count,
            medianMs: $median,
            rawMadMs: $raw_mad,
            normalizedMadMs: $normalized_mad,
            relativeMadPercent: $relative_mad
          }
        end
    end;

def build_summary:
  validate_samples as $samples
  | {
      schemaVersion: 1,
      unit: "milliseconds",
      inputPrecisionMs: {
        inspect: 0.1,
        verify: 0.1,
        launch: 0.1,
        alias: 0.001,
        openDispatch: 0.001,
        exactOwnership: 0.001,
        runtimeTransportPing: 0.001,
        readyGeometry: 0.001,
        total: 0.1
      },
      minimumSampleCount: 5,
      sampleCount: ($samples | length),
      sampleCases: [$samples[].case],
      generationKey: $samples[0].generationKey,
      fixtureAppTreeSHA256: $samples[0].fixtureAppTreeSHA256,
      phases: (
        reduce phase_names[] as $phase (
          {};
          .[$phase] = phase_summary($samples; $phase)
        )
      ),
      samples: $samples
    };

def timing_pattern:
  "^Mac timing: "
  + "inspect=(?<inspect>[0-9]+\\.[0-9])ms "
  + "clone=skipped convert=skipped sign=skipped "
  + "verify=(?<verify>[0-9]+\\.[0-9])ms "
  + "launch=(?<launch>[0-9]+\\.[0-9])ms "
  + "alias=(?<alias>[0-9]+\\.[0-9]{3})ms "
  + "openDispatch=(?<openDispatch>[0-9]+\\.[0-9]{3})ms "
  + "exactOwnership=(?<exactOwnership>[0-9]+\\.[0-9]{3})ms "
  + "runtimeTransportPing="
  + "(?<runtimeTransportPing>(?:[0-9]+\\.[0-9]{3}ms|skipped)) "
  + "readyGeometry=(?<readyGeometry>[0-9]+\\.[0-9]{3})ms "
  + "total=(?<total>[0-9]+\\.[0-9])ms$";

def parse_sample:
  . as $input
  | if ($input | has_exact_keys(
      ["line", "case", "generationKey", "fixtureAppTreeSHA256"]
    ) | not) then
      fail("parse input fields must be exact")
    else
      $input
    end
  | if (
      (.line | type) != "string"
      or (.line | test("[\\r\\n]"))
      or (.line | test(timing_pattern) | not)
    ) then
      fail("timing line does not match the exact warm-start format")
    else
      (.line | capture(timing_pattern)) as $timing
      | {
          case: .case,
          generationKey: .generationKey,
          fixtureAppTreeSHA256: .fixtureAppTreeSHA256,
          phases: {
            inspect: ($timing.inspect | tonumber),
            verify: ($timing.verify | tonumber),
            launch: ($timing.launch | tonumber),
            alias: ($timing.alias | tonumber),
            openDispatch: ($timing.openDispatch | tonumber),
            exactOwnership: ($timing.exactOwnership | tonumber),
            runtimeTransportPing: (
              if $timing.runtimeTransportPing == "skipped" then
                null
              else
                ($timing.runtimeTransportPing | rtrimstr("ms") | tonumber)
              end
            ),
            readyGeometry: ($timing.readyGeometry | tonumber),
            total: ($timing.total | tonumber)
          }
        }
      | validate_sample
    end;

def validate_summary:
  . as $summary
  | if ($summary | type) != "object" then
      fail("validate input must be a summary object")
    else
      ($summary.samples | build_summary) as $rebuilt
      | if $summary == $rebuilt then
          $summary
        else
          fail("summary does not exactly match its recomputed samples")
        end
    end;

if $mode == "parse" then
  parse_sample
elif $mode == "build" then
  build_summary
elif $mode == "validate" then
  validate_summary
else
  fail("mode must be parse, build, or validate")
end
