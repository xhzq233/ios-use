# ios-use v2.1.0-alpha.1

Pre-release of 2.1.0 with external TCP driver attachments. This build includes
the 2.1.0 preparation changes and excludes the separate MCP/REPL experiment.

## Highlights

- Attach to an externally started ios-use driver with
  `ios-use attach --device remote-phone --host <host> --port <port>`.
  The CLI verifies a DOM response before saving the attachment.
- Use native DOM, screenshots, gestures, input, waits, alerts, App activation
  and termination through the endpoint, alongside other Device contexts.
- `detach`, or `stop` on a TCP target, only removes the local binding. The
  provider owns the remote driver and forwards; connection failures never
  start a local XCTest runtime.
- Run multiple Devices in one `IOS_USE_HOME` and install the Skill separately
  on remote consumers.

## Fixes from the 2.1.0 preparation

- Release old snapshot trees while retaining scrolling ancestor context.
- Read the selected Device session and preserve App-readiness identifiers.
- Improve scrolling in sectioned lists and visibility-aware containers.
- Fix IPA metadata inspection and keep installed CLI/Skill versions aligned.

## Install and compatibility

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --version v2.1.0-alpha.1
```

Use the matching Driver IPA. TCP endpoints must be reachable through a trusted
network or secure tunnel. Installation, URL opening, media import, logs and
proxy require the external provider; `activateApp --log` is unavailable over
TCP. `status` reports the saved attachment rather than continuous remote health.

Native quiescence can return during navigation animations; verify the expected
page before collecting results. This is an opt-in alpha; default latest installs
continue using the stable release.
