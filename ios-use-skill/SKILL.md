---
name: "ios-use"
description: "Use ios-use to control apps on a real iOS device, Simulator, or Mac backend, including target setup and platform troubleshooting."
---

# ios-use

Use the App project's context for business entry points and expected results.
Keep an existing local or remote device session; device-host setup is separate
from using that session.

## Native CLI

When using the CLI, discover the target with `ios-use status`. With multiple
running Devices, pass `-d <id>` on UI commands; IDs are bare UDIDs, `mac`, or aliases chosen during TCP attachment.

```bash
ios-use dom
ios-use tap "Continue" --dom
```

Use targets from the current DOM. Bare `--dom` uses the native idle wait;
use `ios-use help <command>` for selectors and options.

## Target setup and other workflows

Read only the reference needed for the task:

- No running target, upgrade, signing, DDI or Mac setup: [setup and recovery](references/setup.md).
- Simulator: [Simulator](references/simulator.md).
- App lifecycle, rotation, screenshots or animation evidence: [App actions and evidence](references/apps-and-evidence.md).
- HTTP/HTTPS capture: [Proxy](references/proxy.md).
- App integrates NSLogger: [NSLogger](references/nslog.md).
- Frida or native dylib patches: [Frida debug](references/frida-debug.md).
- Create/update a GitHub issue: [Report](references/report.md).

## Install or update

On the device's Mac host, install the CLI and Skill:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

For a remote consumer that only needs the Skill:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install_skill.sh | bash
```

Both installers accept `--version <tag>`. From a checkout,
`bash scripts/install_skill.sh` installs its Skill. Set `IOS_USE_INSTALL_SKILL=0`
when the consumer owns Skill discovery and should keep its existing copy.

Keep credentials and signing material out of commands and reports.
Redact device identifiers and signed URLs before sharing artifacts.
