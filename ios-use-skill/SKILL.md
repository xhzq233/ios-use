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
running Devices, pass `-d <id>` on UI commands; IDs are bare UDIDs, `mac`, or aliases chosen with remote start.
Use `ios-use --help` for the workflow and `ios-use help <command>` for command
options and examples.

### Observe, act and verify

```bash
ios-use dom
ios-use tap "Continue" -D
ios-use swipe --to "<target>" --from "<visible-anchor>" -D
ios-use input --tap "Search" --content "<query>" -D
ios-use waitFor "Loading" --match contains --gone --timeout 20s
```

- Target the label or value shown in DOM, not a whole row: for `Result=idle`,
  use `"Result"` or `"idle"`. Narrow repeated matches with `--traits`, or name
  a parent and use `--cindex` to select its child. To reach an offscreen item,
  use its label with a visible anchor in the same list.
- Append `-D` (alias `--dom`) to actions to see the result. `dom` and `-D`
  return a full tree initially, then changes when useful: `+` adds, `-` removes,
  and `~` updates an item. Read changes together with the preceding tree.
- Use `dom --nodiff` when you need the complete current page or no longer have
  the earlier observations. Use `dom --nodiff --json` for element coordinates,
  or `screenshot` to inspect appearance.
- Verify the requested result in the returned output. For loading, use
  `waitFor` with an observed label or loading indicator. `-D 300ms` adds a fixed
  delay; it does not wait for loading to finish.
- If an action fails, read its error and suggested matches before retrying.
  Use `dom` to inspect the current page. On a real device or Simulator,
  `dom --fresh` also rechecks which App is in the foreground.
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
- Frida or native dylib patches: [Frida debug](references/frida-debug.md).
- Create/update a GitHub issue: [Report](references/report.md).

## Install or update

On the device's Mac host, install the CLI and Skill:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

The Skill is installed at `~/.ios-use/skill`. To expose it in another existing
skills directory, create a link:

```bash
ln -s "$HOME/.ios-use/skill" /path/to/skills/ios-use
```

The installer accepts `--version <tag>` and `--no-skill` to skip the default
`~/.agents/skills/ios-use` link. Skill files still update with the CLI; existing
discovery paths are preserved.

Keep credentials and signing material out of commands and reports.
Redact device identifiers and signed URLs before sharing artifacts.

## Linux hosts

Linux x86_64 supports remote devices through a provider connection. Use
ios-use 2.1.0 or newer with a matching Driver.
The provider signs/installs the Driver and keeps the device connection alive:

```bash
ios-use start -d phone --connection device-connection.json
ios-use apps -d phone
ios-use activateApp com.example.app --terminateExisting --log -d phone --json
ios-use dom -d phone
ios-use screenshot -d phone
ios-use stop -d phone
```

ios-use owns XCTest, App management, URL opening and App stdout/stderr. `stop`
stops XCTest and log capture; release the provider lease separately. Linux
screenshots omit OCR. See [setup](references/setup.md) for connection details.
