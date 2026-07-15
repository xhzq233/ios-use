---
name: "ios-use-skill"
description: "Operate iOS real devices and Simulators with the ios-use CLI. Use for session setup, DOM-first UI inspection, tap/swipe/input actions, app lifecycle, screenshots and short captures, log collection, proxy capture, signing recovery, and device troubleshooting."
---

# ios-use Operational Playbook

## 1. Load only the relevant reference

- Read `references/simulator.md` before operating or troubleshooting a Simulator.
- Read `references/proxy.md` before configuring HTTP/HTTPS capture or certificates.
- Read `references/nslog.md` only when the target App already integrates NSLogger.
- Read `references/report.md` before creating or updating a GitHub issue.

Do not load unrelated references preemptively.

## 2. Prepare an active target

For a real device, run:

```bash
ios-use status
ios-use config --udid <udid>
ios-use start <udid>
```

- Connect real devices over USB and use iOS 17.4 or later.
- Run `config` on first use, after upgrading ios-use, when `status` reports
  `driver update required`, or when signing has expired.
- Run `start` before `dom`, `tap`, `longpress`, `swipe`, `input`, `waitFor`,
  `screenshot`, `capture`, `home`, `dismissAlert`, or device-backed proxy commands.
- Treat the device selected by `start` as the target for all UI commands. To switch
  devices, run `ios-use stop`, then `ios-use start <new-udid>`.
- Use `ios-use help <command>` for the complete option contract instead of guessing
  whether an individual command accepts `--udid`.

For first-time signing, ask the user to run:

```bash
ios-use config --udid <udid> --apple-id <email>
```

Omit `--password`; let the CLI request the Apple Developer account password and
two-factor code interactively. A free Personal Team is sufficient.

## 3. Follow the observe-act-verify loop

Inspect the current UI before acting:

```bash
ios-use dom
ios-use waitFor --label "蓝牙" --timeout 8
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
  `--dom <milliseconds>` only when a fixed post-action delay is intentional.
- Keep actions with page-state dependencies sequential. Parallelize only independent
  read-only observations.
- Wait for disappearance with `--gone`:

```bash
ios-use waitFor --label "正在加载" --gone --timeout 10
```

## 4. Use targets deliberately

```bash
ios-use tap "通用"
ios-use tap "亮度" --offset-ratio 0.8,0.5
ios-use longpress "照片" --duration 800
ios-use swipe --dir forth --distance 300
ios-use swipe --to "开发者" --from "蓝牙"
ios-use input --tap "搜索" --content "蓝牙"
```

- Pass only the displayed label or value as the target; do not copy the whole DOM
  line, traits, or coordinates into a label target.
- Use `--traits` or `--cindex` only when the DOM shows duplicate candidates that
  need disambiguation.
- Provide `--from` when `swipe --to` must begin from a known visible scroll anchor.
- Use coordinate targets only for visual controls that Accessibility does not expose.
- On mutation failure, open the returned `Evidence:` manifest and inspect its
  screenshot, OCR, and fresh DOM before running separate diagnostic commands.

## 5. Control Apps and inspect their logs

```bash
ios-use activateApp com.example.app
ios-use activateApp com.example.app --terminateExisting --log
ios-use terminateApp com.example.app
ios-use open "https://example.com"
ios-use dismissAlert
```

When `activateApp --terminateExisting --log` prints a log path, query the file with
standard shell tools:

```bash
rg -n -i 'error|warning|precheck' <log-file>
tail -f <log-file>
```

Do not echo signed URLs, tokens, credentials, or unrelated private log content.

## 6. Collect visual evidence only when needed

Use a screenshot when the DOM cannot describe visual state:

```bash
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
- `signing expires soon`: finish the current short task if appropriate, but refresh
  signing before a long run.
- Element not found or ambiguous: inspect a fresh DOM, use the exact displayed
  label/value, then add `--traits` or `--cindex` only if needed.
- DDI missing or mismatched: use `ddi-mount`, the fallback archive above, and an
  exact device-version match.
- altsign HTTP 4xx: verify Apple Developer account state and interactive
  authentication, then retry `config`.
- altsign HTTP 5xx: check network, VPN, or proxy conditions and retry later; do not
  change device UI state to solve a signing-service failure.
- Signing succeeded but launch still fails: check developer trust and CLI/driver
  version alignment instead of assuming every failure is an altsign problem.

Never place passwords, two-factor codes, certificates, or complete provisioning
profiles in commands, logs, artifacts, or reports. A full UDID is required in some
local commands; redact it before sharing logs, artifacts, or reports.
