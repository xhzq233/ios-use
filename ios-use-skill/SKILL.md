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
options and examples. The CLI help is usable without loading this Skill.

### Observe, act and verify

```bash
ios-use dom
ios-use tap "Continue" -D
ios-use swipe --to "<target>" --from "<visible-anchor>" -D
ios-use input --tap "Search" --content "<query>" --enter -D
ios-use longpress "<target>" --duration 800ms -D
ios-use waitFor "Loading" --match contains --gone --timeout 20s
```

- Use displayed labels/values from current DOM, not the whole DOM line. Use
  `"Result"` or `"idle"` for `Result=idle`, not `"Result=idle"`. Use
  `--traits` / `--cindex` for observed duplicates. Prefer an offscreen semantic
  target with a visible anchor in the same scroll container; use label-relative
  offsets before absolute coordinates when possible.
- For a bounded scroll in one panel, use `swipe --from "<visible-anchor>"
  --dir forth --distance 150 -D`. The anchor can be the scroll container itself
  or a point inside it. Nested containers use their own scroll axis; an invalid
  anchor does not fall back to another panel. Two point endpoints perform a raw drag.
- `dom`, `--dom` and `-D` default to diff. Append `-D` / `--dom` to actions
  to observe their result; the first observation or broad changes return full.
  Keep the initial tree and subsequent changes in context. If context is missing
  (after compaction or handoff), use `dom --nodiff` to recover a full tree.
  Add `--nodiff` to an action with `-D` when its result must be self-contained.
  Unchanged nodes retain their last observed state. Combine earlier observations
  with subsequent changes to verify multiple results; a full DOM is not needed
  just to display those already-observed results together.
- First diff use, changed App/session/size, or broad changes returns full
  automatically. The Driver keeps the last semantic observation across CLI calls.
  Changes show `-` removals, `+` additions and `~` updated rows under shared
  parent context. Removals name the selector; `~` supplies its current state.
  Rows include zero-based child position;
  the position describes tree order, not screen coordinates. Labels remain action targets.
  Normal DOM omits rectangles. Use `dom --nodiff --json` for exact current geometry and
  original label provenance. Layout changes are reported separately and do not
  imply that semantics changed. A detailed/raw read resets the next diff to full.
- Verify the result using the action's observation; request another full DOM
  only when the available context is insufficient. Bare `-D` waits briefly for native
  idle (XCTest waits are bounded); `-D 300ms` uses a fixed delay. Neither an unchanged DOM nor native idle
  proves App readiness; wait on an observed page/loading condition when needed.
- After navigation, scrolling or a failed lookup, refresh stale context before
  choosing the next action; the action's fresh `-D` output already does this.
  Read inline target/candidate/rejection/suggestion/alert
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
