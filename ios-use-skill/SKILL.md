---
name: "ios-use-skill"
description: "Use when a task explicitly requires running, scripting, or troubleshooting the ios-use CLI on a real device, Simulator, or Mac backend, including setup, DOM-first UI actions, app lifecycle, screenshots, logs, proxying, signing, Frida debugging, and Frida-loaded native dylib patches."
---

# ios-use Operational Playbook

## Preserve repeatable workflows early

Treat a working command sequence as a reusable asset. As soon as an
exploratory route succeeds, preserve its stable labels, waits, and any debug
setup in a named `.sh` script in the App's project instead of rediscovering the
same route later.

This is a strong recommendation when a route repeats, installs debug hooks, or
may continue across turns or sessions. It is not a gate for a genuinely
one-off action. Persist semantic labels rather than coordinates, make setup
idempotent, and use fail-fast execution so later mutations do not run after an
earlier failure.

```bash
#!/usr/bin/env bash
set -euo pipefail

entry_label='入口'
target_label='目标'
visible_anchor='当前可见项'

ios-use waitFor "$entry_label" --timeout 10s
ios-use tap "$entry_label" --dom
ios-use swipe --to "$target_label" --from "$visible_anchor" --dom
ios-use tap "$target_label" --dom
```

Keep page-dependent UI actions sequential. Parallelize only independent
read-only observations. For a short dependent sequence, joining commands with
`&&` provides the same fail-fast behavior without requiring a script.

## Install or update ios-use

Use the same command for both the initial installation and every update:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

## 1. Load only the relevant reference

- Read `references/simulator.md` before operating or troubleshooting a Simulator.
- Read `references/proxy.md` before configuring HTTP/HTTPS capture or certificates.
- Read `references/nslog.md` only when the target App already integrates NSLogger.
- Read `references/frida-debug.md` before using `debug` or a Frida-loaded
  native dylib patch.
- Read `references/report.md` before creating or updating a GitHub issue.

Do not load unrelated references preemptively.

## 2. Prepare an active target

For a real device, run:

```bash
ios-use status
ios-use config --udid <udid>
ios-use start <udid>
```

For the Mac backend, complete its one-time setup and start an App:

```bash
ios-use config --mac
ios-use start --mac --app <App.app>
```

`config --mac` asks for macOS authentication. If authentication is cancelled,
rerun the same command. This setup is shared across `IOS_USE_HOME` values.

Use a distinct `IOS_USE_HOME` for each concurrent ios-use session. This allows
multiple Mac Apps with different bundle IDs (or independent device sessions) to
run at the same time while sharing the one-time Mac signing setup and installed
Mac Apps. The Mac backend intentionally rejects two concurrent copies of the
same bundle ID.

`start --mac --app <App.app>` automatically reuses an unchanged installed App
or updates it after the source changes. Every Mac App includes the Frida debug
Engine, so `ios-use debug` works for any Mac session. Later,
`ios-use start --mac` launches the current `IOS_USE_HOME`'s remembered App.
Run `ios-use stop` before switching backends.

After upgrading ios-use, Apps installed by older versions are not migrated or
auto-launched: run `start --mac --app` once per bundle ID. ios-use never
deletes old caches for you; run `ios-use du` to see what you can remove.

- Connect real devices over USB and use iOS 17.4 or later.
- Run `config` on first use, after upgrading ios-use, when `status` reports
  `driver update required`, when signing expires soon, or when signing has
  expired. Refresh before expiry instead of deferring renewal across sessions.
- Run `start` before `dom`, `ui-tree`, `tap`, `longpress`, `swipe`, `input`, `waitFor`,
  `screenshot`, `capture`, `home`, `dismissAlert`, default `activateApp`,
  `open --dom`, or device-backed proxy commands.
- Treat the device selected by `start` as the target for all UI commands. To switch
  devices, run `ios-use stop`, then `ios-use start <new-udid>`.
- After `start --mac`, supported commands continue using that Mac session until
  `ios-use stop`.
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

## 3. Follow the observe-act-verify loop

Inspect the current UI before acting:

```bash
ios-use dom
ios-use waitFor "蓝牙" --timeout 8s
```

Then perform one state-changing action and verify the new state:

```bash
ios-use tap "通用" --dom
ios-use swipe --to "开发者" --from "蓝牙" --dom
ios-use input --tap "搜索" --content "蓝牙" --dom
```

- Prefer DOM labels and values over raw coordinates.
- After navigation, scrolling, or an element lookup failure, request a new DOM
  before choosing the next action.
- Use bare `--dom` to wait for quiescence and return a fresh DOM. Use
  `--dom <duration>` only when a fixed post-action delay is intentional; suffix
  explicit values with `ms` or `s`.
- Wait for disappearance with `--gone`:

```bash
ios-use waitFor "正在加载" --gone --timeout 10s
```

For changing labels, pass a stable substring instead of copying one transient value:

```bash
ios-use waitFor "优化身形线条中" --match contains --gone --timeout 55s
```

## 4. Use targets deliberately

```bash
ios-use tap "通用"
ios-use tap "亮度" --offset-ratio 0.8,0.5
ios-use longpress "照片" --duration 800ms
ios-use swipe --to "开发者" --from "蓝牙"
ios-use swipe --dir forth --distance 300
ios-use input --tap "搜索" --content "蓝牙"
```

- Pass only the displayed label or value as the target; do not copy the whole DOM
  line, traits, or coordinates into a label target.
- Use `--traits` or `--cindex` only when the DOM shows duplicate candidates that
  need disambiguation.
- Prefer `swipe --to ... --from ...` for a labeled off-screen target. Use its exact
  displayed text and a currently visible anchor from the same scroll container.
- Use coordinate taps, coordinate anchors, or fixed-distance swipes only when
  Accessibility exposes no usable semantic target. Prefer a label-relative offset
  before an absolute coordinate.
- On mutation failure, read the inline target, candidate, rejection, suggestion,
  and alert fields first. Request a fresh `dom` or named `screenshot` only when
  the next decision needs more UI context.

## 5. Control Apps and inspect their logs

The commands in this section are for real devices and Simulators. For the Mac
backend, use only `start`, `status`, and `stop` for lifecycle.

```bash
ios-use activateApp com.example.app
ios-use activateApp com.example.app --dom
ios-use activateApp com.example.app --no-wait
ios-use activateApp com.example.app --terminateExisting --log
ios-use terminateApp com.example.app
ios-use open "https://example.com"
ios-use open "https://example.com" --dom
ios-use dismissAlert --only-button
ios-use dismissAlert --label "Allow Full Access"
```

- Normal `activateApp` waits for the App to reach the foreground and for one fresh
  UI snapshot. Add `--dom` to return that snapshot, or use `--no-wait` only when
  host launch acknowledgement is sufficient.
- `open` only dispatches the URL by default. Add `--dom` for immediate foreground
  UI evidence, then use `waitFor` for the destination condition that matters.
- `dismissAlert` requires an explicit or unambiguous button choice. Use
  `--only-button` for a one-button alert, `--label` or `--index` for a known
  multi-button alert, and `--primary` only when the visual trailing/top heuristic
  is intentional.

When `activateApp --terminateExisting --log` prints a log path, query the file with
standard shell tools:

```bash
rg -n -i 'error|warning|precheck' <log-file>
tail -f <log-file>
```

Do not echo signed URLs, tokens, credentials, or unrelated private log content.

### Debug a Mac App with Frida

When runtime implementation details matter, use semantic DOM to name the
current UI and `ui-tree` to relate one label to its UIKit subtree:

```bash
ios-use dom
ios-use ui-tree --target "导入照片" --depth 6
```

`ui-tree` is read-only and Mac-only. It shows current view classes, hierarchy,
geometry, and common public properties; continue to use `dom` labels for UI
actions. View frames use their parent's coordinates; use DOM geometry for the
screen position. Request a fresh tree after the UI changes.

Read `references/frida-debug.md` first. Prefer stdin for multi-line GumJS and
use an explicit reset when a failed script may have installed hooks:

```bash
ios-use start --mac --app /path/to/App.app
ios-use debug - < probe.js
ios-use debug --reset
```

Script source is not saved, but variables and hooks created by a script persist
until reset or App exit. Reset does not undo changes the script already made
inside the App.

Use Frida JS directly for discovery, observation, small hooks, and changing
existing App state. For a substantial new UIKit hierarchy, page replacement,
animation, or interaction state machine, put the implementation in an arm64 Mac
Catalyst dylib and use Frida as its loader and runtime control plane. Read
`references/frida-debug.md` for the export contract and the required
install-state-restore workflow. The dylib may be compiled locally or remotely;
ios-use does not require the compiler to run on the same Mac as the App.

## 6. Collect visual evidence only when needed

Use a screenshot when the DOM cannot describe visual state:

```bash
ios-use dom
ios-use screenshot --name result
ios-use screenshot --no-ocr --name pixels-only
```

Use a short image sequence for transient animation:

```bash
ios-use tap "站姿1" && ios-use capture --fps 10 --duration 3 --name pose-sweep
ios-use capture --fps 10 --duration 3 --name pose-sweep --keep-changed-frames
```

- Keep `tap` and `capture` as separate shell commands.
- Use `--keep-changed-frames` when only visually changed JPEGs are useful.
- Expect JPEG files and `manifest.json`, not video, GIF, or a contact sheet.

## 7. Manage installed Apps and DDI

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
