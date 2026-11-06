# iOS Self Runner (experimental)

An on-device host for ios-use automation. The app imports a trusted host pairing
record, connects to its own developer services, initializes XCTest in its own
process, and executes scripts without a desktop XCTest holder.

## Implementation plan

- Reuse the Swift Lockdown, CoreDevice/RSD and DTX implementations.
- Delay loading the UI automation framework until the local developer connection
  and XCTest session are ready.
- Offer an embedded, narrowly routed packet tunnel and an external VPN option.
- Import and run sequential JSON scripts with waits, assertions, bounded repeats,
  cancellation, and visible per-step results.
- Verify on a leased physical device, including stopping the desktop XCTest
  holder before starting the on-device session.

The embedded packet tunnel requires a signing profile supporting Network
Extensions. An external VPN avoids that entitlement on the runner app. Neither
route removes pairing, Developer Mode, DDI, automation authorization or signing
expiry requirements. Cloud platform signing does not validate Personal Team
compatibility.

This is an implementation in progress. Build instructions and verified platform
results will be updated as the implementation is exercised.
