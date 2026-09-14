# App actions and visual evidence

### Rotate a real device or Simulator

```bash
ios-use rotate --to landscape-right --dom --json
```

Supported orientations are `portrait`, `portrait-upside-down`, `landscape-left`,
and `landscape-right`. The command changes the simulated physical orientation;
an App that supports only portrait can remain portrait. Use `--dom` to inspect the
resulting App layout. `rotate` requires an active real-device or Simulator Driver
and is unavailable on the Mac backend.

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

Read `frida-debug.md` first. Prefer stdin for multi-line GumJS and
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
`frida-debug.md` for the export contract and the required
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
