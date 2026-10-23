# macOS 27 and iOS 27 Simulator validation

2026-10-23 · macOS 27.0.1, Xcode 27.1, Swift 6.4. Mac measurements use the
Release CLI and Runtime at `c77709f3`, the public UIKit Fixture rebuilt with the
27.1 SDK, and the iPhone 13 layout (390 × 844 at 3x). Simulator checks use the
matching rebuilt Driver and the installed iOS 27.1 Duo runtime. These are
separate backends and workloads.

## Compatibility findings

- On the tested iOS 27.1 Duo Simulator, `XCUIDevice.press(.home)` returned success
  after 5,550 ms while the App remained visible. The iOS 27 Simulator path now
  activates SpringBoard through the existing LaunchServices adapter and checks
  foreground readiness without requesting a DOM snapshot. Three subsequent
  calls returned to the actual Home screen in 159, 139 and 135 ms, verified by
  DOM and independent Simulator framebuffer screenshots. The real-device and
  older-Simulator paths retain the Home-button implementation. Expanded Duo
  mode was not included in these three checks.
- This host's installed iOS 27.1 runtime lists only iPhone Duo in
  `supportedDeviceTypes`; creating an ordinary iPhone with it fails as
  incompatible. This is a property of the installed runtime, not a claim about
  every iOS 27 distribution. Test scripts now share compatible runtime/device
  selection, honor explicit selections and reject stale cached mismatches.
  Six selection tests and 127 Driver unit tests passed; the latter ran on the
  actual Duo runtime.
- The default Swift 6.4 build, Runtime linkage, invalid PlayChain key decoding,
  decorated tab labels, cooperative snapshot cancellation and interrupted Mac
  launch recovery are covered by the preceding fixes in PR #43. The current
  account's public-fixture core live gate passed, including 20 lifecycle cycles.
- Cold SwiftUI accessibility discovery remains an acceptance item: an earlier
  run exposed only its input field before external accessibility inspection.
  A fresh fixture bundle in this run exposed all eight SwiftUI nodes, but a new
  login/boot without prior accessibility inspection has not been tested. This
  observation does not establish a fix. A final three-process restart check
  also read the SwiftUI counter and verified its increment each time.
- The original TikTok test package is unavailable locally. Its checkout hang
  and layout symptoms remain unverified; the key-decoding crash fix alone does
  not prove those symptoms are resolved.

## Historical Mac comparison

CLI process wall time, in milliseconds. Setup and verification are outside the
timer. DOM uses 20 samples per operation; other rows use six. The historical
column comes from [the September benchmark](benchmark.md), on macOS 15.7.7
with release `aca8dc0b`. The machine is now upgraded, so there is no controlled
OS-only A/B: source, compiler, SDK and fixture build also differ. These numbers
are not an iOS 18 versus iOS 27 Simulator comparison.

| Operation | macOS 15 median | macOS 27 median | macOS 27 mean |
| --- | ---: | ---: | ---: |
| Full DOM | 26.7 | 25.9 | 34.6 |
| Unchanged DOM | 30.2 | 29.4 | 41.9 |
| Wait for present element | 29.8 | 23.2 | 23.3 |
| Screenshot without OCR | 76.4 | 67.7 | 70.2 |
| Coordinate tap | 91.2 | 71.2 | 71.5 |
| Label tap | 108.5 | 73.6 | 72.9 |
| Tap with offset ratio | 101.9 | 75.8 | 75.8 |
| Long press, 500 ms | 569.8 | 574.6 | 575.2 |
| Input two characters | 165.1 | 149.5 | 148.0 |
| Scroll 200 pt | 445.5 | 450.2 | 451.1 |
| Wait timeout, 2 s | 2,052.0 | 2,036.5 | 2,038.3 |

The long-press and scroll medians are about 1% higher. This small sample does
not establish a persistent regression. DOM medians remain close, but means are
higher than the historical 28.1/29.6 ms: full/unchanged DOM P95 was 72.5/79.4 ms,
with maxima 101.7/160.0 ms. Slow successful samples were retained.

A separate three-process startup check with the final Release CLI and JSON
output measured command return at 1,048–1,166 ms and the first verified UIKit
DOM at 1,084–1,208 ms. Preparation/signing was completed beforehand. This is
not a paired historical startup comparison; command return and UI readiness
must not be treated as the same completion condition.

Action samples were checked against fixture callbacks. The coordinate tap uses
the uncovered left portion of the button because the fixture deliberately
overlays its center. List scrolling uses a stable left-list identifier and
checks that adjacent lists do not move. Earlier harness attempts that targeted
the covered center, selected the other list's duplicate label, or expected an
incorrect timeout code failed verification and are not counted as successful
samples. Their evidence was retained locally.

## Same-host Runtime comparison

To distinguish PR overhead from an OS change, the fixed `c77709f3` CLI and
fixture were run with two Runtime builds on this macOS 27 host: `d1aeb78b`
(key-decoding/SDK fixes, before the cancellation and tab-owner changes) and
`c77709f3`. Order was current → earlier → earlier → current, with five warmups
per phase and 100 full plus 100 unchanged DOM samples per variant overall.
No build or Simulator test ran during measurement.

| Runtime | Full DOM mean / median / P95 | Unchanged DOM mean / median / P95 |
| --- | ---: | ---: |
| Earlier `d1aeb78b` | 33.2 / 27.5 / 54.8 | 35.7 / 28.6 / 71.1 |
| Current `c77709f3` | 30.6 / 29.4 / 43.2 | 29.3 / 27.8 / 45.0 |

The full-DOM median increased about 1.9 ms (7%), while its mean and P95 improved;
unchanged DOM improved on all three measures. App CPU averaged 0.865 versus
0.840 seconds per 100 commands. Long tails also occur with the earlier Runtime.
This bounded experiment does not support attributing all jitter to the new
code, or declaring a universal speedup. Process RSS was roughly 119–124 MiB;
there is no comparable macOS 15 memory baseline.

An additional ancestor-walk rewrite was tested and reverted after its DOM
median became approximately 8% slower. It is not part of the shipped changes
or the current-Runtime row above.

## Remaining coverage

- Repeat on an older supported macOS/Xcode host and on an iOS 18 Simulator.
- Repeat cold SwiftUI discovery after a fresh login/boot without an inspector.
- Validate the original TikTok navigation, session persistence and checkout.
- Repeat the Home-screen check with Duo expanded and other supported iOS 27
  Simulator models as their runtimes become available.

The CLI/Driver protocol and public command arguments remain unchanged. Updating
Xcode/runtime requires rebuilding the Simulator Driver; running Mac mode does
not use the installed iOS Simulator runtime. Compatibility warnings remain
enabled until the outstanding UI acceptance is complete.
