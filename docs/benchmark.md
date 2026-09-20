# Benchmark

2026-09-20 · Release `aca8dc0b`, matching CLI and Driver/Runtime. Mean / median CLI wall time in ms; setup and verification are outside the timer. DOM: 20 runs, other commands: 6, session start/stop: 3. WDA reuses the May 30 measurements.

| Operation | USB mean / median | May ios-use mean | WDA mean | Mac mean / median |
| --- | ---: | ---: | ---: | ---: |
| Start session | 2,087.8 / 2,100.2 | 1,954.8 | 10,753.6 | 1,834.4 / 1,840.6 |
| Full DOM | 241.5 / 245.0 | 20.7 (cached) | 965.7 | 28.1 / 26.7 |
| Unchanged DOM | 253.0 / 252.2 | — | — | 29.6 / 30.2 |
| Wait for present element | 194.1 / 196.7 | 14.0 | 308.7 | 35.4 / 29.8 |
| Wait timeout (2s) | 2,208.3 / 2,252.3 | 2,270.2 | 2,365.2 | 2,051.0 / 2,052.0 |
| Screenshot (no OCR) | 71.1 / 74.8 | 81.2 | 179.0 | 85.5 / 76.4 |
| Coordinate tap | 367.5 / 363.1 | 424.6 | 556.3 | 90.6 / 91.2 |
| Label tap | 598.6 / 596.7 | 413.2 | 1,076.3 | 107.6 / 108.5 |
| Tap with offset ratio | 585.2 / 586.9 | 415.0 | 947.8 | 102.9 / 101.9 |
| Long press (500ms) | 786.0 / 784.8 | 828.7 | 1,038.8 | 569.5 / 569.8 |
| Input two characters | 957.3 / 957.2 | 1,630.5 | 1,717.6 | 172.1 / 165.1 |
| Scroll 200 pt | 2,013.3 / 2,029.4 | 2,170.6 | 2,620.3 | 445.7 / 445.5 |
| Scroll 150 pt in the selected list | — | — | — | 451.3 / 451.0 |
| Find offscreen row | 9,471.5 / 9,463.0 | 10,799.2 | 17,050.9 | 270.7 / 270.5 |
| Find already-visible row | 293.5 / 289.3 | — | — | 35.1 / 34.2 |
| Coordinate drag | 1,505.8 / 1,283.6 | — | — | 446.6 / 446.0 |
| Label-to-label drag | 1,244.6 / 1,252.3 | — | — | 446.0 / 446.1 |
| Activate App | 606.3 / 608.8 | 78.6 | 1,446.7 | — |
| Terminate App | 260.5 / 253.5 | 1,195.1 | 1,144.0 | — |
| Stop Mac session | — | — | — | 1,251.3 / 1,246.8 |

- USB: iPhone18,3, iOS 26.5.1, Settings. Mac: macOS 15.7.7 arm64, UIKit Fixture, iPhone 13 layout. They are separate workloads; WDA is the USB comparison.
- DOM captures a fresh tree on every call. Full/diff alternate on a stable page after two warmups; all diff observations were unchanged. The old 20.7 ms cache-hit result is not a full recapture.
- USB startup launches a stopped XCTest Driver after a 30-second settle. Mac startup launches an already-prepared Fixture; installation/signing are excluded. Mac App lifecycle uses `start/stop`, so `activateApp/terminateApp` are unsupported.
- Coordinate tap and long press use an inert area on USB, as in the May workload. Semantic taps open Bluetooth; input inserts “蓝牙” into an empty Settings search field. Mac actions are verified using selected rows, long-press callbacks and edited text. Screenshot files were decoded and visually checked. Timeout is the expected result for the 2-second missing-element case.
- Current `activateApp` includes foreground and snapshot readiness. This does more work than a launch-dispatch-only measurement.
- Cold-launch finding: 11/12 initial semantic taps hit the wrong row while Settings restored its list position. The warm-page rerun waits one second during preparation and passed 12/12. The table uses that complete rerun; the original failures are retained separately and are not claimed as fixed in the product.
- All reported prepared-page samples passed their checks: USB 63/63 and Mac 54/54 in this completion run, in addition to the separately measured DOM and swipe samples. No slow samples were dropped. One earlier 2754 ms USB coordinate drag remains in its mean.

Run the USB suite after configuring a matching Driver:

```bash
node scripts/benchmark.js --bench ios-use --udid <udid> \
  --driver-ipa <matching-driver.ipa> --preset full --iterations 6
```
