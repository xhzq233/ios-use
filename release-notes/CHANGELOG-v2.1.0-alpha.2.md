# ios-use v2.1.0-alpha.2

This 2.1.0 pre-release adds a Linux x86_64 TCP client alongside Darwin arm64.
It includes external Driver attachments and the multi-device CLI changes from
alpha.1. The separate MCP/REPL experiment is not included.

## Changes

- Linux can attach to an externally managed Driver and run DOM, gestures,
  text input, waits, App activation/termination, Home and JPEG screenshots.
- The Linux binary statically links the Swift runtime. Ubuntu 22.04 or a
  compatible system with glibc 2.35+ and libstdc++ can run it without Swift.
- Linux screenshots derive pixel dimensions from JPEG metadata and logical
  coordinates from the Driver's scale.
- Client and Driver use the upstream Fory Linux-support revision. Use the
  matching Driver IPA included in this release.
- CLI help is more concise, and device-specific examples use placeholders.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.0-alpha.2/scripts/install.sh | bash -s -- --version v2.1.0-alpha.2
```

Assets: `ios-use-darwin-arm64`, `ios-use-linux-x86_64`, `driver.ipa`,
`driver-sim.ipa`, `ios-use-mac-resources.tar.gz` and `SHA256SUMS`.

The provider handles device allocation, signing, installation, port forwarding
and XCTest startup. Attach with a local alias:

```bash
ios-use attach -d phone --host '<driver-host>' --port '<forwarded-port>'
ios-use dom -d phone
ios-use detach -d phone
```

TCP endpoints must be reachable through a trusted network or secure tunnel.
Detaching, or stopping a TCP target, removes its local binding while the
provider retains ownership of the remote Driver.

## Validation and limits

Native Linux x86_64 real-device validation covered attachment, DOM, semantic
scrolling, tapping, waiting, Chinese input, JPEG screenshots, App lifecycle and
cleanup. macOS, Driver and native Linux CI suites passed.

Linux supports TCP attachments only. OCR, capture sequences, local USB,
Simulator, Mac, logging and proxy services require macOS. App installation,
URL opening and media import remain provider operations for TCP targets.

A control label can collide with the App label; use a fresh DOM and an observed
coordinate when needed. A scroll target absent from the current accessibility
tree may require an explicit `forth` or `back` direction. Verify the expected
page after navigation before collecting results.

This is an opt-in alpha. Default latest installs continue using the stable
release.
