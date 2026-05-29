# Benchmark

This benchmark compares `ios-use` against the full `Appium Server -> WebDriverAgent` stack on the same app scenario.

## Setup

- App: `com.apple.Preferences`
- Device: real iPhone over USB/usbmuxd
- Custom side: Swift CLI + custom XCTest TCP driver
- Baseline: Appium Server + WDA
- Iterations: `3`
- Report date: 2026-05-18

Current benchmark runs require an explicit custom driver IPA. The script does not build driver artifacts itself:

```bash
node scripts/benchmark_wda.js --driver-ipa .ios-use/driver.ipa --iterations 3
```

## Results

| Case | ios-use Avg (ms) | Appium+WDA Avg (ms) | Reduction |
| --- | ---: | ---: | --- |
| `start_and_activate_app` | 3257.4 | 9622.1 | `66.1%` |
| `dom` | 13.5 | 984.2 | `98.6%` |
| `find` | 15.7 | 279.8 | `94.4%` |
| `waitFor` | 13.7 | 277.2 | `95.1%` |
| `screenshot` | 45.5 | 215.0 | `78.8%` |
| `tap_coord` | 377.3 | 557.3 | `32.3%` |
| `tap_label` | 542.8 | 1089.5 | `50.2%` |
| `longpress_coord` | 819.9 | 967.4 | `15.2%` |
| `input` | 1534.0 | 1760.8 | `12.9%` |
| `swipe_distance` | 2062.5 | 2595.4 | `20.5%` |
| `scroll_to_visible` | 10717.0 | 17123.0 | `37.4%` |
| `activate_app` | 1213.7 | 2591.1 | `53.2%` |
| `terminate_app` | 1141.4 | 1164.7 | `2.0%` |

## Notes

Numbers vary by device, app state, and whether the target page is already warm, but the shape is stable: `dom`, `find`, `waitFor`, `tap`, and screenshot are the operations that most improve AI-facing responsiveness.

In this run, the `input` custom average is calculated from two successful iterations; one prepare step failed with a transient driver TCP read error and is tracked separately from the latency comparison.
