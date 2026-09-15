# Target setup and recovery



For a real device, run:

```bash
ios-use status
ios-use config --udid <udid>
ios-use start <udid>
```

For an externally started driver, obtain its forwarded endpoint from the device
provider and connect using a local alias:

```bash
ios-use start --device remote-phone --host <host> --port <port>
ios-use dom -d remote-phone
ios-use stop -d remote-phone
```

Use a driver from the same release over a trusted network or secure tunnel.
No local `config` is needed. Do not mix host/port with a UDID or local start flags.
`attach` accepts the same endpoint options for compatibility (use it on Alpha 3).
`detach` and `stop` only forget this
attachment; the provider owns installation, driver startup, and cleanup.
If disconnected, restore the endpoint through the provider and retry. If the
endpoint changed, stop and start with the new endpoint. `status` reports the saved binding and its lifecycle owner;
run `dom` to check whether the endpoint is currently responsive.
Host operations such as install, open, media import, logs and proxy require the
provider; `activateApp --log` is unavailable over TCP.

For the Mac backend, complete its one-time setup and start an App:

```bash
ios-use config --mac
ios-use start --mac --app <App.app>
```

Select a Mac device preset with `ios-use config --mac --device-model <preset>`:
`iphone-se`, `iphone-13`, `iphone-15-pro`, `iphone-15-pro-max` (default), or
`ipad-pro-11`. Stop the App and cold-start it again to apply the selection.
Changing the preset does not restart an App or initialize signing. The active
`macDevice` and pending `configuredMacDevice` are shown by `status --json`.

On macOS 26 or newer, `start --mac` warns and continues, but Mac UI interaction
is not fully supported and may crash. Prefer a validated older macOS host, a
real device, or a Simulator for reliable automation.

`config --mac` asks for macOS authentication. If authentication is cancelled,
rerun the same command. This setup is shared across `IOS_USE_HOME` values.

One `IOS_USE_HOME` can hold multiple independent Device Contexts. `status`
prints their stable IDs: the bare UDID for a real device or Simulator, `mac`, or the TCP attachment alias. When more
than one Device runs, pass `-d <device-id>` (or `--device`) to every Device command;
with exactly one running Device, it remains optional.

```bash
ios-use dom -d '<udid>'
ios-use screenshot -d mac
ios-use stop -d '<udid>'
```

Use distinct Homes only when you need multiple Mac Apps at once. The Mac
backend intentionally rejects two concurrent copies of the same bundle ID.

`start --mac --app <App.app>` automatically reuses an unchanged installed App
or updates it after the source changes. Every Mac App includes the Frida debug
Engine, so `ios-use debug` works for any Mac session. Later,
`ios-use start --mac` launches the current `IOS_USE_HOME`'s remembered App.
Starting or stopping `mac` does not replace another Device Context.

After upgrading ios-use, Apps installed by older versions are not migrated or
auto-launched: run `start --mac --app` once per bundle ID. ios-use never
deletes old caches for you; run `ios-use du` to see what you can remove.

- Connect real devices over USB and use iOS 17.4 or later.
- Run `config` on first use, after upgrading ios-use, when `status` reports
  `driver update required`, when signing expires soon, or when signing has
  expired. Refresh before expiry instead of deferring renewal across sessions.
- Run `start` before `dom`, `ui-tree`, `tap`, `longpress`, `swipe`, `input`, `waitFor`,
  `screenshot`, `capture`, `home`, `dismissAlert`, default `activateApp`,
  `open --dom`, `rotate`, or device-backed proxy commands.
- Use the Device ID returned by `status` on all UI commands when multiple
  Device Contexts are running.
- After `start --mac`, supported commands can select it with `-d mac`.
- Mac lifecycle is only `start`, `status`, and `stop`. Do not use `home`,
  `activateApp`, or `terminateApp` for a Mac session. Restart it with
  `ios-use stop`, then `ios-use start --mac`.
- Use `ios-use help <command>` for the complete option contract instead of guessing
  whether an individual command accepts `--udid`.

For first-time real-device signing, run:

```bash
~/.ios-use/altsign-cli/altsign-cli list --apple-id '<Apple ID>'
ios-use config --udid <udid>
```

AltSign reads the password and any two-factor code from standard input. When
standard input is a terminal, password echo is disabled and restored by
AltSign. ios-use never reads either secret or inspects AltSign login state. A
free Personal Team is sufficient.

After the first successful login, ios-use normally reuses the cached Apple
Developer authentication for up to one year. Routine `config` renewals therefore
usually do not require the Apple ID, password, or two-factor code again. If the
AltSign signing output says its single cached session is missing or expired, ask
the user to run the login command above and then retry the same `config` command.

Renew real-device signing with `config` within each seven-day signing window. If
signing is allowed to expire, installing the newly signed driver requires the
user to open Settings on the device and manually trust the developer again.
Avoid that interruption by checking `status` and refreshing while the current
driver is still valid.


## Apps and DDI


```bash
ios-use apps --udid <udid>
ios-use install path/to/signed.ipa --udid <udid>
ios-use uninstall com.example.app --udid <udid>
ios-use ddi-mount --udid <udid>
```

- Install only signed `.ipa` or `.app` artifacts.
- Confirm the bundle ID before uninstalling an App.
- Let `ddi-mount` inspect local caches first.
- If no matching DDI exists locally, download the current fallback archive:

```text
https://deviceboxhq.com/ddi-17E5179g.zip
```

Extract it and pass the matching `Restore/`, `iOS_DDI/`, or `.dmg` path to
`ddi-mount --path`. Do not mount a version that does not match the device.

## 8. Recover from common failures

- `No active driver`: run `ios-use status`, then `ios-use start <udid>`.
- `driver update required`, `signing expired`, or a driver that no longer launches:
  rerun `ios-use config --udid <udid>`, then start again.
- `signing expires soon`: run `config` while the current driver is still valid;
  do not defer renewal across a long or multi-session task.
- Element not found or ambiguous: inspect a fresh DOM, use the exact displayed
  label/value, then add `--traits` or `--cindex` only if needed.
- DDI missing or mismatched: use `ddi-mount`, the fallback archive above, and an
  exact device-version match.
- The Mac backend reports missing or incomplete installed resources: reinstall or
  update ios-use from a complete release, then retry the same `start --mac --app`
  command.
- Mac setup is missing or macOS trust needs attention: run
  `ios-use config --mac`. If macOS authentication was cancelled, safely retry
  that same command.
- altsign HTTP 4xx: verify Apple Developer account state and interactive
  authentication, then retry `config`.
- altsign HTTP 5xx: check network, VPN, or proxy conditions and retry later; do not
  change device UI state to solve a signing-service failure.
- Signing succeeded but launch still fails: check developer trust and run
  `ios-use status`. If it reports `driver update required`, rerun
  `ios-use config --udid <udid>` before starting again.

Never place passwords, two-factor codes, certificates, or complete provisioning
profiles in commands, logs, artifacts, or reports. A full UDID is required in some
local commands; redact it before sharing logs, artifacts, or reports.
