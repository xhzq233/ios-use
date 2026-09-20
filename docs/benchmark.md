# Benchmark

This benchmark compares `ios-use` against the full `Appium Server -> WebDriverAgent` stack on the same real-device Settings scenario. Lower latency is better.

## Setup

- App: `com.apple.Preferences`
- Device: real iPhone over USB/usbmuxd
- ios-use side: Swift CLI + custom XCTest TCP driver
- Baseline side: Appium Server + WebDriverAgent
- Iterations: `3` for command cases, `1` for cold `start_session`
- Report date: 2026-05-30
- Result: both sides completed 17 cases with 0 failures

The benchmark runner only measures. It does not build, sign, install, or run `config`; prepare the device and driver outside the benchmark first.

```bash
# ios-use
node scripts/benchmark.js --bench ios-use \
  --udid <device-udid> \
  --driver-ipa .ios-use/driver.ipa \
  --preset full \
  --iterations 3

# Appium/WDA
node scripts/benchmark.js --bench wda \
  --udid <device-udid> \
  --wda-bundle-id <wda-runner-bundle-id> \
  --preset full \
  --iterations 3
```

The two benches run separately and write separate JSON reports. Compare them by matching the same case id.

## Results

| Case | ios-use Avg (ms) | Appium+WDA Avg (ms) | Reduction |
| --- | ---: | ---: | ---: |
| `start_session` | 1954.8 | 10753.6 | 81.8% |
| `dom_cached` | 20.7 | 965.7 | 97.9% |
| `wait_for_present` | 14.0 | 308.7 | 95.5% |
| `wait_for_timeout_2000ms` | 2270.2 | 2365.2 | 4.0% |
| `screenshot` | 81.2 | 179.0 | 54.6% |
| `tap_coord` | 424.6 | 556.3 | 23.7% |
| `tap_label` | 413.2 | 1076.3 | 61.6% |
| `tap_offset_ratio` | 415.0 | 947.8 | 56.2% |
| `longpress_coord` | 828.7 | 1038.8 | 20.2% |
| `input` | 1630.5 | 1717.6 | 5.1% |
| `scroll_distance_semantic` | 2170.6 | 2620.3 | 17.2% |
| `scroll_to_visible` | 10799.2 | 17050.9 | 36.7% |
| `activate_app` | 78.6 | 1446.7 | 94.6% |
| `terminate_app` | 1195.1 | 1144.0 | -4.5% |

## Case Notes

- `dom_cached` and `wait_for_present` represent the tight AI loop: observe the UI and wait for visible state.
- `wait_for_timeout_2000ms` is intentionally dominated by a 2-second timeout on both sides.
- `screenshot` compares pixel capture only: ios-use runs `screenshot --no-ocr`, so host-side Vision OCR is excluded from both sides.
- `tap_label` and `tap_offset_ratio` are semantic actions: ios-use performs label lookup plus action in one CLI command; the WDA side performs the equivalent find/frame/action sequence.
- `scroll_to_visible` is an end-to-end workflow case, not a raw gesture primitive.
- `activate_app` and `terminate_app` are measured as app lifecycle commands after prepare puts the app in the expected state.
- `terminate_app` is roughly parity in this run, with WDA slightly faster.

The former `find_*` benchmark cases were removed with the public `find` command; use `waitFor` for read-side existence checks and action commands for semantic targeting. Numbers vary by device, iOS version, app state, and whether the target page is already warm. The stable shape is that read-heavy agent operations and semantic actions avoid most of the Appium/WDA HTTP stack overhead.

## Screenshot Backend Probe (2026-07-14)

A focused real-device probe compared the available screenshot paths over one already-open CoreDevice tunnel:

| Path | Warm latency | Result |
| --- | ---: | --- |
| XCTest driver `XCRequestScreenshotJPEG` | 28–32 ms | Fastest available path in this run |
| Instruments screenshot DTX service | 68–74 ms | First request was 208 ms; warm requests remained slower |
| CoreDevice physical-device screenshot action | N/A | No screenshot service was advertised by Remote Service Discovery |

The direct CoreDevice design would remove the host-to-driver command and the driver's XCTest screenshot request layer, but it would still cross a RemoteXPC/system screenshot service boundary. On the tested iOS 26.5.1 device no physical-device screenshot service was advertised. The installed CoreDevice framework only exposed an Apple-internal `SnapshotFetchScreenshotsAction` whose API targets virtual machines. The DTX alternative added protocol overhead and was slower, so the production command keeps XCTest JPEG capture.

CoreDevice Display Info is queried in parallel for every real-device screenshot. Reusing the holder's tunnel while opening the service's one-request RemoteXPC connection took about 14–20 ms warm. It stayed off the screenshot critical path in the real-device samples; structured timings are written as `[screenshot-perf]` records in the CLI log and per-frame fields in `capture` manifests.

## Swipe interface comparison (2026-09-20, PR #27)

Before: main `815132ff`. After: `aca8dc0b`. Both are Release builds with matching CLI and XCTest Driver or Mac Runtime. The before group is the immediate pre-PR main, **not the published v2.1.0 binary**. This comparison does not rerun Appium/WDA or update the historical DOM numbers above.

Each existing case has six samples per group, split into blocks of three: after/before/before/after on USB, before/after/after/before on Mac. Only CLI process wall time is measured, without `-D`. Installation, startup, identical page reset, full DOM reads and effect verification are outside the timer. All measured commands and slow samples are retained. Old semantic `--to` is compared with new `--find`; new label-to-label dragging is a separate case.

USB Settings: iPhone18,3, iOS 26.5.1, 402×874 logical canvas. The two original swipe workloads use a 200-point default scroll and Bluetooth → Developer search. Every trial starts at the same top offset. Search checks target visibility and then actually opens the reached row; scroll/drag checks row movement. Coordinates are identical between groups. One preparation attempt paused because AX changed a text frame without moving its row; the harness resumed using the enclosing row's position, without replacing any timing sample.

| USB case | Before mean / median (ms) | After mean / median (ms) | Verified before → after |
| --- | ---: | ---: | ---: |
| Default scroll, 200 pt | 1932.2 / 1927.4 | 2013.3 / 2029.4 | 6/6 → 6/6 |
| Find offscreen Developer row | 9518.7 / 9518.7 | 9471.5 / 9463.0 | 6/6 → 6/6 |
| Find already-visible Bluetooth row | 1585.6 / 1585.2 | 293.5 / 289.3 | 6/6 → 6/6 |
| Coordinate drag | 1281.1 / 1289.2 | 1505.8 / 1283.6 | 6/6 → 6/6 |
| Label-to-label drag (new) | — | 1244.6 / 1252.3 | — → 6/6 |

The visible-target case is 81.5% faster on average because it avoids an unnecessary scroll; the old implementation moved the row about 160 points while the new one left it in place. Offscreen search is nearly unchanged. Fixed-distance scroll averages 4.2% slower (+81 ms). Coordinate drag has nearly unchanged median, but one 2754 ms sample raises the new mean by 17.5%; that sample is not discarded. Six samples cannot establish a fleet-wide latency or tail-latency conclusion.

Mac: macOS 15.7.7 arm64, the same Release UIKit Fixture and iPhone 13 layout (390×844) for both groups. App-written offsets, selected rows and delivered touch endpoints verify effects independently of command success. All trials reset the three scroll containers first.

| Mac case | Before mean / median (ms) | After mean / median (ms) | Verified before → after |
| --- | ---: | ---: | ---: |
| Default scroll, 200 pt | 441.3 / 445.4 | 445.7 / 445.5 | 6/6 → 6/6 |
| Anchored left-list scroll, 150 pt | 444.5 / 442.6 | 451.3 / 451.0 | 6/6 → 6/6 |
| Find offscreen left row 15 | 272.1 / 275.8 | 270.7 / 270.5 | 6/6 → 6/6 |
| Find already-visible row | 30.4 / 31.1 | 35.1 / 34.2 | 6/6 → 6/6 |
| Coordinate drag | 443.1 / 445.0 | 446.6 / 446.0 | 6/6 → 6/6 |
| Label-to-label drag (new) | — | 446.0 / 446.1 | — → 6/6 |

The tested Mac operations remain close in latency. Across USB and Mac, all 120 measured commands passed their effect checks. This supplements the separate correctness regression suite; it is not a claim that every swipe scenario became faster.
