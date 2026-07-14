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
