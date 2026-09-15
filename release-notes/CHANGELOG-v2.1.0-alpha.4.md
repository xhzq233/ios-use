# ios-use v2.1.0-alpha.4

This pre-release unifies local and external Driver sessions under `start`,
turns screenshot OCR off by default, and fixes App-root element lookup and
foreground detection after external App switches. It includes Darwin arm64
and native Linux x86_64 clients. MCP/REPL remains a separate experiment.

## Changes

- `start -d <id> --host <host> --port <port>` connects to an already running
  external Driver on macOS or Linux. It shares endpoint validation and protocol
  probing with the compatible `attach` command.
- Local `start <udid>` retains ownership of Driver startup and shutdown.
  Remote `stop` only removes the local binding, including while offline.
  `status` reports `lifecycleOwner` as `ios-use` or `external`.
- Screenshots save JPEGs without OCR by default on both hosts. macOS users
  can add `--ocr` for Vision text recognition; `--no-ocr` remains supported.
- Application roots remain in DOM output but are excluded from element search
  and suggestions. A back button sharing the App's label is now selectable
  directly with its Button trait.
- On XCTest targets, `dom --fresh` redetects the foreground App after an
  external device service launches an App or opens a URL.
- Release construction runs the Linux CLI, Mac CLI, both Driver variants and
  Mac resources in independent jobs, followed by assembly and isolated
  installation verification. Compatible compiler caches are reused.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.0-alpha.4/scripts/install.sh | bash -s -- --version v2.1.0-alpha.4
```

Use the matching CLI and Driver IPA from this release. Assets are
`ios-use-darwin-arm64`, `ios-use-linux-x86_64`, `driver.ipa`, `driver-sim.ipa`,
`ios-use-mac-resources.tar.gz` and `SHA256SUMS`.

For an externally started Driver:

```bash
ios-use start -d phone --host '<driver-host>' --port '<forwarded-port>'
ios-use dom -d phone
ios-use screenshot -d phone
ios-use stop -d phone
```

The provider owns signing, installation, port forwarding, XCTest startup and
remote cleanup. Use a trusted network or secure tunnel for the TCP endpoint.

## Validation and limits

The feature commit passed all four CI jobs, including 437 macOS host tests
(5 skipped), 109 Driver tests and the Linux x86_64 tests/build. End-to-end
validation covered a local Simulator and real iPhone sessions from native
Linux x86_64 and macOS: unified start, default screenshots, explicit Mac OCR,
compatible attach, stop without terminating the external Driver, and offline
unbinding. External App switches, URL transitions and App-root back-button
selection were verified on real devices.

Linux supports external TCP Drivers. It has no local USB, Simulator, Mac,
OCR, capture-sequence, logging or proxy backend. Device installation, URL
opening, App log capture and media import remain provider operations for TCP
targets. Remote status records a binding and does not continuously probe health.

A scroll target absent from the current accessibility tree may require an
explicit direction. The Mac App backend retains its documented macOS 26 UI
compatibility limitations. Default latest installs continue using the stable
release; this alpha must be selected explicitly.
