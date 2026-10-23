# macOS 27 and iOS 27 validation

2026-10-23 · macOS 27.0.1, Xcode 27.1, Swift 6.4, iOS 27.1 Duo Simulator.
Mac measurements use the Release CLI and Runtime at `c77709f3` with the public
UIKit Fixture rebuilt using the 27.1 SDK and the iPhone 13 layout (390 × 844).

## Results

- Release CLI and Mac Runtime build with Swift 6.4.
- Mac core live checks passed, including DOM, taps, input, scrolling and
  20 start/stop cycles. Three process restarts verified the SwiftUI counter.
- Invalid PlayChain keys return errors; expired DOM reads cancel, decorated
  tabs resolve to their controls, and `stop` recovers interrupted launches.
- Simulator `home` returned to SpringBoard in 159, 139 and 135 ms, verified by
  DOM and framebuffer screenshots. Runtime/device selection tests and
  127 Driver unit tests passed on the Duo runtime.

Fresh-login SwiftUI discovery, the original TikTok checkout and expanded Duo
Home were not exercised in this run.

## Mac command timing

CLI wall time in milliseconds. DOM uses 20 samples; other rows use six.
Historical results are from [macOS 15.7.7](benchmark.md) at `aca8dc0b`.
Source, compiler, SDK and fixture builds differ between the two runs.

| Operation | macOS 15 median | macOS 27 median |
| --- | ---: | ---: |
| Full DOM | 26.7 | 25.9 |
| Unchanged DOM | 30.2 | 29.4 |
| Wait for present element | 29.8 | 23.2 |
| Screenshot without OCR | 76.4 | 67.7 |
| Coordinate tap | 91.2 | 71.2 |
| Label tap | 108.5 | 73.6 |
| Tap with offset ratio | 101.9 | 75.8 |
| Long press, 500 ms | 569.8 | 574.6 |
| Input two characters | 165.1 | 149.5 |
| Scroll 200 pt | 445.5 | 450.2 |
| Wait timeout, 2 s | 2,052.0 | 2,036.5 |

Full/unchanged DOM P95 was 72.5/79.4 ms. Three process startups returned in
1,048–1,166 ms; the first verified UIKit DOM arrived in 1,084–1,208 ms.
Preparation and signing were completed before timing.

## Runtime comparison on macOS 27

The same CLI and fixture used Runtime `d1aeb78b` and `c77709f3`, with 100 full
and 100 unchanged DOM samples per variant. No concurrent builds or Simulator
tests ran during measurement.

| Runtime | Full DOM mean / median / P95 | Unchanged DOM mean / median / P95 |
| --- | ---: | ---: |
| Earlier `d1aeb78b` | 33.2 / 27.5 / 54.8 | 35.7 / 28.6 / 71.1 |
| Current `c77709f3` | 30.6 / 29.4 / 43.2 | 29.3 / 27.8 / 45.0 |

App CPU used 0.865 versus 0.840 seconds per 100 commands; RSS was 119–124 MiB.
