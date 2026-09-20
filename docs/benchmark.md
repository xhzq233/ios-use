# Benchmark

2026-09-20 · Release development build `aca8dc0b` ([PR #27](https://github.com/xhzq233/ios-use/pull/27)), with matching CLI and Driver/Runtime.

CLI wall time in ms, including output. DOM uses 20 runs per mode after two warmups; swipe/drag uses six. Setup, page reset and verification are outside the timer.

## USB real iPhone — Settings

iPhone18,3 · iOS 26.5.1 · 402×874. Offscreen target: Developer.

| Operation | Mean (ms) | Median (ms) | Successful runs |
| --- | ---: | ---: | ---: |
| Full DOM (`dom --nodiff`) | 241.5 | 245.0 | 20/20 |
| Unchanged DOM (`dom`) | 253.0 | 252.2 | 20/20 |
| Scroll 200 pt | 2013.3 | 2029.4 | 6/6 |
| Find offscreen row | 9471.5 | 9463.0 | 6/6 |
| Find already-visible row | 293.5 | 289.3 | 6/6 |
| Coordinate drag | 1505.8 | 1283.6 | 6/6 |
| Label-to-label drag | 1244.6 | 1252.3 | 6/6 |

## Mac Backend — UIKit Fixture

macOS 15.7.7 arm64 · iPhone 13 layout, 390×844. Offscreen target: left row 15.

| Operation | Mean (ms) | Median (ms) | Successful runs |
| --- | ---: | ---: | ---: |
| Full DOM (`dom --nodiff`) | 28.1 | 26.7 | 20/20 |
| Unchanged DOM (`dom`) | 29.6 | 30.2 | 20/20 |
| Scroll 200 pt | 445.7 | 445.5 | 6/6 |
| Find offscreen row | 270.7 | 270.5 | 6/6 |
| Find already-visible row | 35.1 | 34.2 | 6/6 |
| Coordinate drag | 446.6 | 446.0 | 6/6 |
| Label-to-label drag | 446.0 | 446.1 | 6/6 |
| Scroll 150 pt in the selected list | 451.3 | 451.0 | 6/6 |

Every DOM call captures a fresh tree. Full and diff calls alternate on a stable page; all measured diff responses reported no semantic change.

Swipe effects were verified through row movement, opening reached targets, and Fixture scroll/touch callbacks. Slow samples remain included: one 2754 ms USB coordinate drag raises its mean above its median.

These are separate App workloads, not a cross-backend speed comparison. WDA and commands absent from these tables have not been remeasured.

To measure full DOM with the repository runner after configuring the device:

```bash
node scripts/benchmark.js --bench ios-use --udid <udid> \
  --driver-ipa <matching-driver.ipa> --cases dom_full --iterations 20
```
