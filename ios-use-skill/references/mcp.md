# MCP automation

Use the ios-use MCP `js` tool for a dependent automation flow that benefits from persistent
JavaScript variables, reusable Device handles, or concurrent work across
independent Devices. The Swift Host stays in the same process and reuses Driver
connections; JavaScript actions do not launch another `ios-use` process.

## Register the server

Configure a local stdio server with command `ios-use` and argument `mcp`.
For Codex:

```bash
codex mcp add ios-use -- ios-use mcp
```

Start a new Agent session after registration. Node.js 22.18+ must be on the
server's PATH. Call `js` with a `code` string, an optional short `title`, and
optional `timeout_ms` (default 30,000; maximum 300,000). JavaScript variables
persist between calls. Await the tool result; do not use shell polling.

The injected surface is deliberately small: `cua`, `nodeRepl`, and
`console`. Filesystem, process, network, module-import, and worker APIs are not
available to evaluated code.

## Discover and select a Device

Follow the Codex CUA shape: discover from `cua`, then operate directly on a
target object.

```javascript
let state = await cua.getState({emit: false});
let device = await cua.getDevice("mac");
device.help();
```

Use the stable IDs returned by `cua.getState()`: the bare device/Simulator UDID,
or `mac`. Never infer a target from list order.
Once an ID is known, `cua.getDevice(id)` selects it directly without repeating
global Device discovery. Selection emits the initial AX observation automatically;
pass `{emit: false}` as the second argument when only the handle is needed.

## Observe, act, observe

Device methods follow the native Computer Use target shape:

```javascript
await device.getAXState();
await device.getScreenshot();
await device.getAXStateAndScreenshot();

await device.click(12);
await device.click(12, {clickCount: 2});
await device.setValue(7, "hello");
await device.getAXState({emit: false});
await device.selectText(7, "hello", {selectionType: "cursor_after"});
await device.typeText(" world");
await device.paste("text");
await device.pressKey("Return");
await device.drag([120, 400], [120, 250]);
await device.longPress("A visible control", 0.5);
await device.scroll(4, "down", 0.5);
await device.scrollTo("Settings", "Home");
await device.waitFor("Loading", {gone: true, timeout: 20});
```

AX and screenshot observations wait for UI animations to settle by default.
Use `{waitQuiescence: false}` only when an immediate unsettled observation is
intentional. This uses the Driver's
quiescence wait, not a fixed sleep; use `waitFor` for a particular loading state.
`scroll` accepts positive fractional pages: `0.5` requests half a viewport
along the requested direction, not a whole swipe rounded up.

Observations emit text or images into the tool result by default. Pass `{emit: false}` when the value is
only an intermediate result. AX observations are diffed against the previous
observation for the same Device; pass `{disableDiffing: true}` when a full
snapshot is required.
`device.get()` returns the full current element objects even when the text
output is a diff. Each includes `depth`, `parent_index`, `children`, and
`ancestor_indices`; use that hierarchy to scope controls to the relevant page
or container. Screenshot bytes also carry `logicalSize`, `pixelSize`, and `scale`.

```javascript
let ax = await device.getAXState({emit: false});
let full = await device.getAXState({emit: false, disableDiffing: true});
```

An `element_index` belongs to the latest AX observation. After a screenshot-only
observation, obtain a new AX state before using an index. After `click`,
`setValue`, `selectText`, `typeText`, `paste`, `pressKey`, `drag`, `longPress`, or `scroll`, observe again before
using an index. Prefer semantic text when it is unique; the runtime falls back
to the observed element center only when needed.

`setValue` replaces the whole editable value, including with an empty string.
`typeText` inserts at the current cursor or replaces the current selection.
`selectText(index, text, {prefix, suffix, selectionType})` requires one literal
match; use adjacent `prefix` / `suffix` text to disambiguate duplicates.
`selectionType` is `text` (default), `cursor_before`, or `cursor_after`.
Selection and replacement are checked against the native editable state.
If native selection cannot be confirmed or its time budget expires, stop and
observe; do not type assuming the requested selection exists.

On iOS and Simulator, `pressKey` accepts xdotool-style names and chords, such as
`Left`, `BackSpace`, `Return`, `shift+Left`, and `super+a`. `ctrl` is Control;
`super` / `cmd` is Command, not an alias for Control. Use `typeText` for Unicode
text rather than passing an emoji or combining sequence as a physical key.
`clickCount` is 1–10. iOS clicks are touch-only (`mouseButton: "left"`);
use `longPress` for a context menu, not a right-click alias.

## Batch repeated work

Explore enough of an unfamiliar UI to understand the route and relevant page
variants. Then use a reusable helper and a loop to process the requested items
in one `js` call where practical. Do not split a known repeated flow into one
model round trip per click or item.

Keep actions on one Device sequential, but make the intermediate observations
and decisions inside the script. After each navigation, read fresh AX with
`{emit: false, waitQuiescence: true}` and use `device.get()` to inspect the full
current element objects, including labels, values and selected states. The AX
text return value may be only a diff; do not treat it as the whole page or reuse
old element indices. Select fields using the active page's context: a flat list
of every switch can include duplicate controls or nodes from a previous page.

Accumulate the requested results and emit a compact summary. Handle page
variants only when their visible state makes the next step clear. If a page is
unexpected or an action fails, return the completed results and current state
for the model to resolve; do not continue the loop blindly. Batching does not
expand permission to change settings or take other external actions.

## Emit explicit results

Use the same output helpers as Codex Node REPL:

```javascript
let state = await device.getAXState({emit: false});
nodeRepl.write(state);

let image = await device.getScreenshot({emit: false});
await nodeRepl.emitImage(image);
```

Do not print every intermediate object. Emit the observation or artifact that
helps the caller understand the final result.
Use `nodeRepl.write(...)` or `console.log(...)` for other values; JavaScript
return values are not echoed a second time after the API has emitted its result.

For multi-turn work, reuse variables in the next `js` call. `js_reset` interrupts
running JavaScript and clears its variables and handles, without stopping
Drivers or Apps. Timeout and request cancellation also reset the context.
Ordinary JavaScript errors preserve it. No `.exit` or terminal session is needed.
Remote connection and artifact transfer follow the transport's own Skill;
do not treat an Edge-local path as a Consumer file.
`paste` currently inserts plain text; Markdown/HTML clipboard formats and
`performSecondaryAction` are not implemented. Secure-field replacement and
selection are unavailable because the text cannot be verified; focus and use
`typeText` when entering a secret is authorized. The Mac backend currently
supports single clicks and Return/Enter keys only. Use native CLI commands for
lifecycle, installation, logs and capture.
After upgrading, restart a running Mac App with the current ios-use build before
using MCP text editing; older runtimes cannot preserve these selection semantics.

## Coordinate independent Devices

Device handles keep their own identity and AX history, so independent Devices
may run concurrently:

```javascript
let state = await cua.getState({emit: false});
let mac = await cua.getDevice("mac");
let simulatorID = state.devices.find(item => item.kind === "simulator")?.id;
if (!simulatorID) throw new Error("No Simulator is available");
let simulator = await cua.getDevice(simulatorID);

await Promise.all([
  mac.getAXState(),
  simulator.getAXState(),
]);
```

Keep actions on one Device sequential. Use `Promise.all` only across independent
Devices or independent read-only observations.

## Recover from failures

Device command failures throw `IOSUseCommandError` with the CLI error category,
retryability, interaction state, and mutation warning. Inspect those fields
before retrying a mutation:

```javascript
try {
  await device.click("Continue");
} catch (error) {
  nodeRepl.write({
    message: error.message,
    category: error.category,
    retryable: error.retryable,
    mutationMayHaveApplied: error.mutationMayHaveApplied,
    interaction: error.interaction,
  });
}
```

If `mutationMayHaveApplied` is true, observe first instead of replaying the
action blindly. After cancellation, timeout, or reset, obtain a new Device handle
and observe again: actions already sent to a Driver may still finish. The MCP
client releases the JavaScript runtime and cached connections on disconnection;
use native `ios-use stop -d <id>` only when stopping the Driver is part of the task.
