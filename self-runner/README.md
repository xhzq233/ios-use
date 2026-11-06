# iOS Self Runner (experimental)

Self Runner is an iOS app that hosts its own Lockdown, CoreDevice/RSD, DTX and
XCTest session. Import a script, start automation, and run the steps on the
phone. A desktop XCTest holder is not needed at execution time.

The app loads the existing ios-use UI implementation as a framework **after**
local developer services and XCTest are ready. The standard CLI and Driver
continue using their existing host-managed lifecycle.

## Prepare a device

Use an already-trusted device with Developer Mode enabled and a matching
Developer Disk Image mounted. DDI mounting is currently a preparation step;
the app does not download or mount the image itself.

Export the trusted host's pairing credential and enable that host's wireless
developer connection (also required for the local VPN route):

```sh
python3 scripts/prepare_self_runner.py --udid '<device-id>' --output pairing.plist
```

A remote provider can supply its existing connection descriptor instead:

```sh
python3 scripts/prepare_self_runner.py --connection device-connection.json --output pairing.plist
```

This uses the existing pairing; it does not create a new identity or ask for an
Apple account password. The output is owner-only and is never overwritten.
Treat it as a device credential, import it into the app, and remove the exported
copy when it is no longer needed. `--skip-wireless` exports without changing the
host's wireless connection setting.

## Build and install

From the repository root, with Xcode and XcodeGen installed:

```sh
# Standalone packet tunnel included; needs Network Extensions signing support.
bash scripts/build_self_runner.sh --embedded-vpn

# App without the extension; use an external loopback VPN.
bash scripts/build_self_runner.sh
```

The unsigned IPA and build log are under
`${IOS_USE_HOME:-.ios-use}/self-runner/`. Sign and install the app using your
normal device provisioning or provider workflow. Sign nested frameworks and,
for the embedded build, keep and provision the packet tunnel extension too.
The generated Xcode project is a build artifact; edit `project.yml` and
`project-embedded.yml` as the source of truth.

The embedded extension requires a profile supporting
`com.apple.developer.networking.networkextension` with `packet-tunnel-provider`.
Free Personal Team provisioning does not provide that capability. The external
VPN build avoids that entitlement on the runner app, but its free-signing
compatibility has not been verified on a physical device.

## Run in the app

1. Import the pairing record using **Import pairing record**. Credentials are
   stored in the protected Application Support directory, excluded from backup,
   rather than the file-sharing Documents directory.
2. Enable **Use embedded local VPN**, or connect an external loopback VPN first.
   The default peer is `10.7.0.1`. The embedded tunnel routes only that address;
   it does not forward Internet traffic.
3. Tap **Start automation**. Accept the system's VPN, network and automation
   authorization requests. Background location permission is used to keep an
   explicitly started session running while switching apps; it does not promise
   indefinite background execution.
4. Paste a JSON script or use **Import JSON script**, then tap **Run script**.
   The steps execute serially. A failure stops the script.
5. **Cancel script** stops between commands and during sleeps; an already-running
   XCTest call finishes or times out first. **Stop session** also closes the
   device connections and stops the embedded VPN and background updates.

Results appear in the app. The latest image and full raw DOM are also written
to `Documents/last-screenshot.jpg` and `Documents/last-dom.txt`; a local session
log is available as `Documents/session.log`. These can contain screen content.

## Script format

```json
{
  "name": "Open Settings",
  "steps": [
    {"command": "home"},
    {"command": "activateApp", "args": {"bundleID": "com.apple.Preferences"}},
    {"command": "dom"},
    {"command": "screenshot"},
    {"count": 2, "steps": [
      {"command": "sleep", "args": {"seconds": 0.5}},
      {"command": "screenshot"}
    ]}
  ]
}
```

| Command | Arguments |
| --- | --- |
| `home`, `dom`, `screenshot` | None |
| `activateApp` | `bundleID` |
| `tap` | `label`, or both `x` and `y`; optional `traits` for labels |
| `longPress` | Same target; `duration` in seconds (default 1, maximum 30) |
| `input` | Same target; `text` |
| `waitFor` | Same target; `timeout` in seconds (default 10, maximum 300), optional `gone` |
| `swipe` | `fromLabel` or `fromX`/`fromY`, and `toLabel` or `toX`/`toY` |
| `sleep` | `seconds` between 0 and 300 |
| `assertText` | `text` that must occur in the current raw DOM |

Coordinates are logical screen points. Labels must match the device's current
language and screen. See [screen.json](examples/screen.json) for a language-neutral
smoke script and [settings.json](examples/settings.json) for an English Settings
example. [settings-search-zh.json](examples/settings-search-zh.json) is the 14-step
Chinese Settings flow exercised on iOS 26.2. Repeats use `count` (1–100) and nested `steps`; a script is limited to
1 MiB, eight nested repeat levels and 1,000 expanded commands. Expansion and
script syntax are checked before any action is dispatched.

For controlled device testing, launch arguments can load
`Documents/script.json` and start it with `--start-automation --run-script`;
add `--embedded-vpn` to use the embedded tunnel. A legacy or explicitly staged
`Documents/pairing.plist` is validated, moved to protected storage on launch,
and removed from Documents. `--remove-local-configuration` removes this app's
VPN configuration and imported pairing record without starting automation.

## Validation and limits

The script executor and packet reflection tests run without a device:

```sh
swift test --package-path self-runner/Core
```

Validated on a physical iPhone 17 running iOS 26.2, using platform development
signing and the embedded packet tunnel. The desktop XCTest holder was stopped
before the app established its own local Lockdown/heartbeat/CoreDevice/RSD/DTX
and XCTest session. The app completed a 14-step script: Home, activate Settings,
wait for and tap Search, enter Chinese text, wait for results, assert text, DOM,
screenshot, Home, and two sleep/screenshot repetitions. The process remained
running in the background while controlling Settings. A cold app restart and
another independent on-device session also succeeded.

Both IPA variants build. The external variant was inspected to confirm it has
no packet tunnel extension and still contains the delayed UI framework; its
external-VPN runtime and Personal Team signing were not physically verified.
Core tests cover packet reflection, malformed packets, script expansion limits,
ordering, failure, cancellation and text assertions. The host CLI general test
suite passed 281 tests (2 skipped).

This uses private XCTest interfaces and a classic pairing-record connection.
Do not assume it works on every iOS version, especially versions that reject
classic Lockdown over a loopback VPN. Device restart, DDI availability, trust,
signing expiry, passcodes and OS background limits still apply.
