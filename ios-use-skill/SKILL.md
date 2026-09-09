---
name: "ios-use-skill"
description: "Use when running or troubleshooting ios-use on a real iOS device, Simulator, or Mac backend. Covers target setup, DOM-first UI actions, persistent REPL, App lifecycle and evidence; signing, proxy and Frida are loaded only when needed."
---

# ios-use

This skill owns platform operation, not App-specific navigation or remote transport.
Use the App project's context for business entry points and assertions. When a
transport already provides an ios-use session, keep using that session; do not
reconfigure the Consumer as a device host.

## Select the workflow

- **Existing target:** `ios-use status`, then use the returned Device ID. With
  multiple running Devices, pass `-d <id>` / `--device <id>` on every UI command.
  IDs are bare UDIDs or `mac`; with one running target the selector is optional.
- **Persistent or multi-device work:** read [REPL](references/repl.md), then
  `ios-use repl`. `cua.getDevice(id)` shows initial AX; explore one action at a
  time, preserving Device handles. Ask `cua.help()` / `device.help()` for APIs.
- **No running target, upgrade, signing, DDI or Mac setup:** read
  [setup and recovery](references/setup.md). Real-device preparation is
  `config --udid <udid>` then `start <udid>`; do not renew an already healthy
  running target merely to observe it.
- **Simulator:** read [Simulator](references/simulator.md).
- **App launch, rotation, screenshots or animation evidence:** read
  [App actions and evidence](references/apps-and-evidence.md).
- **HTTP/HTTPS capture:** read [proxy](references/proxy.md).
- **App integrates NSLogger:** read [NSLogger](references/nslog.md).
- **Frida or native dylib patches:** read [Frida debug](references/frida-debug.md).
- **Create/update a GitHub issue:** read [report](references/report.md).

Read only the references relevant to the current task. Use `ios-use help <command>`
for complete options instead of guessing flags or mirroring a command manual.

## Observe → act → verify

```bash
ios-use dom
ios-use tap "通用" --dom
ios-use swipe --to "开发者" --from "蓝牙" --dom
ios-use input --tap "搜索" --content "蓝牙" --dom
ios-use waitFor "正在加载" --gone --timeout 10s
```

- Serialize actions that depend on page state. Parallelize only independent
  Devices or independent read-only observations.
- Prefer displayed labels/values. Do not copy the entire DOM line as a target.
  Use `--traits` / `--cindex` only to disambiguate observed duplicates.
- Prefer a labeled offscreen target with a visible anchor in the same container.
  If no semantic target is available, use an observed coordinate or fixed-distance
  swipe. A label-relative `--offset-ratio 0.8,0.5` is preferable to an absolute tap.
- Navigation, scrolling and lookup failures invalidate old UI assumptions. Read
  fresh DOM before selecting the next action. Bare `--dom` waits for quiescence;
  add a duration only for an intentional fixed delay, with `ms` or `s` suffix.
- For changing labels, wait on a stable substring:
  `ios-use waitFor "优化身形线条中" --match contains --gone --timeout 55s`.
- On failure, read inline target/candidate/rejection/suggestion/alert fields first.
  Capture a screenshot when the decision requires visual information.
- Preserve a repeatable successful route as a small fail-fast script in the App
  project when it will be reused. Store labels and waits, not stale coordinates.

## Install or update

Run on the device's Mac host:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

The installer also updates this Skill. A Linux Agent using a remote device can
install only the Skill, without a Mac binary or device setup:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install_skill.sh | bash
```

Set `IOS_USE_REF` to the Edge's source revision when pinning versions. From a
source checkout, `bash scripts/install_skill.sh` installs the local Skill.

Never put passwords, 2FA codes, certificates or provisioning profiles in commands
or reports. Redact device identifiers and signed URLs before sharing artifacts.
