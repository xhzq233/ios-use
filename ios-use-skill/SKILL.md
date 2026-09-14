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
running Devices, pass `-d <id>` on UI commands; IDs are bare UDIDs or `mac`.
Use `ios-use --help` for the workflow and `ios-use help <command>` for command
options and examples. The CLI help is usable without loading this Skill.

### Observe, act and verify

```bash
ios-use dom
ios-use tap "Continue" --dom
ios-use swipe --to "<target>" --from "<visible-anchor>" --dom
ios-use input --tap "Search" --content "<query>" --dom
ios-use waitFor "Loading" --match contains --gone --timeout 20s
```

- Use displayed labels/values from current DOM, not the whole DOM line. Use
  `--traits` / `--cindex` for observed duplicates. Prefer an offscreen semantic
  target with a visible anchor in the same scroll container; use label-relative
  offsets before absolute coordinates when possible.
- Verify the result using the action's `--dom` output. Native idle does not
  guarantee App readiness; wait on an observed page/loading condition when needed.
  An explicit `--dom <duration>` is a fixed delay, not a readiness check.
- After navigation, scrolling or a failed lookup, refresh stale context before
  choosing the next action. Read inline target/candidate/rejection/suggestion/alert
  details first; request `dom --fresh` or a screenshot when more context is needed.
- Keep page-dependent actions sequential. Batch known steps with `&&` so failure
  stops later mutations; inspect intermediate UI when the next step is not known.
  Parallelize only independent Devices or independent read-only observations.
- Save successful reusable routes as small `.sh` scripts in the App project with
  `set -euo pipefail`, stable labels and waits, rather than rediscovering them or
  retaining stale coordinates. A one-off action does not require a saved script.

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
