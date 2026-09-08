# REPL 模式

Use `ios-use repl` for a dependent automation flow that benefits from persistent
JavaScript variables, reusable Device handles, or concurrent work across
independent Devices. The Swift Host stays in the same process and reuses Driver
connections; JavaScript actions do not launch another `ios-use` process.

## Start the REPL

Choose the shortest input form that fits the task:

```bash
ios-use repl 'await cua.getState()'
ios-use repl --file task.js
ios-use repl - < task.js
ios-use repl
```

Inline, file, and stdin input run once. Bare `ios-use repl` opens an interactive
Node REPL. The injected surface is deliberately small: `cua`, `nodeRepl`, and
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

Device methods align with the native Computer Use REPL:

```javascript
await device.getAXState();
await device.getScreenshot();
await device.getAXStateAndScreenshot();

await device.click(12);
await device.setValue(7, "hello");
await device.typeText(" world");
await device.paste("text");
await device.pressKey("Return");
await device.scroll(4, "down", 1);
await device.scrollTo("Settings", "Home");
await device.waitFor("Loading", {gone: true, timeout: 20});
```

Observations emit to the REPL by default. Pass `{emit: false}` when the value is
only an intermediate result. AX observations are diffed against the previous
observation for the same Device; pass `{disableDiffing: true}` when a full
snapshot is required.

```javascript
let ax = await device.getAXState({emit: false});
let full = await device.getAXState({emit: false, disableDiffing: true});
```

An `element_index` belongs to the latest AX observation. After a screenshot-only
observation, obtain a new AX state before using an index. After `click`,
`setValue`, `typeText`, `paste`, `pressKey`, or `scroll`, observe again before
using an index. Prefer semantic text when it is unique; the runtime falls back
to the observed element center only when needed.

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

For remote interactive work, keep one Shell process open and send the next JS
line after inspecting the preceding output:

```bash
device-relay exec --stdin - --artifacts ./artifacts <edge> -- ios-use repl
```

Use the Shell tool's existing session input mechanism; send `.exit` when done.
Do not use `repl -` for this: it reads one whole program until stdin EOF.
With Relay `--artifacts`, emitted screenshots are transferred during execution
and the Consumer prints their local `Artifact:` paths. Read those images with
the Agent's image tool; a terminal cannot itself render an image tool result.
`paste` inserts plain text, not clipboard HTML; `pressKey` currently supports
Return only. Use native CLI commands for lifecycle, installation, logs and capture.

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

REPL command failures throw `IOSUseCommandError` with the CLI error category,
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
action blindly. Exit the REPL when the task is complete so the Host releases its
cached Driver connections.
