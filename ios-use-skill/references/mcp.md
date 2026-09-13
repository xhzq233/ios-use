# MCP automation

Use the ios-use `js` tool for UI actions. JavaScript variables and Device handles
persist across calls. The runtime provides `cua`, `nodeRepl` and `console`,
not Node.js filesystem, process or network APIs.

## Register and select

Register a stdio server with command `ios-use` and argument `mcp`, then start
a new Agent session. For Codex:

```bash
codex mcp add ios-use -- ios-use mcp
```

When the Device ID is unknown, start with:

```javascript
await cua.getState();
```

Select a returned bare UDID or `mac`; a known ID can be selected directly:

```javascript
let device = await cua.getDevice("device-id");
```

Selection displays API help and initial AX. Use `device.help()` or `cua.help()`
when more API detail is needed. With an idle configured Device, select with
`{observe: false}` and call `await device.start()`. Signing and Mac App setup
remain native CLI workflows; see [setup](setup.md).

Device actions address its current foreground App. On iOS or Simulator,
`device.activateApp(bundleId)` selects an installed App and returns initial AX.
Use `device.listApps()` when its installed bundle ID is unknown.

## Workflow

After one or more UI actions, call `getAXState()` before deciding what to do next.
Use element indices from that latest observation. Batch deterministic actions
and the resulting observation in the same call:

```javascript
await device.click(42);
await device.getAXState();
```

- Use the observation's default native idle wait; do not add an arbitrary delay
  before capturing state. App-specific loading may outlast native idle:
  `waitFor(text, {gone: true, timeout: 20})` can wait for an observed loading label.
- If a standalone AX read reports no change, do not immediately repeat it
  without an intervening action. Use a screenshot, combined AX/image, or full
  AX only when it supplies missing context.
- Prefer element indices when AX exposes the target. Use screenshots and
  coordinates when the target is visual or AX actions are unavailable.
- Once the requested result is visibly present, stop exploring and respond.
  An action completing is not by itself evidence that the task succeeded.

## Observations and output

`getAXState()`, `getScreenshot()` and `getAXStateAndScreenshot()` emit their
results automatically, as do discovery and selection. Do not print those
results a second time. Pass `{emit: false}` when consuming an intermediate
observation inside JavaScript; use `nodeRepl.write(value)` for task results and
`nodeRepl.emitImage(image)` for an explicitly retained image.

AX text is diffed against the last AX emitted by an observation method.
Prefer this default; `{disableDiffing: true}` requests full text without changing
the wait. Silent reads refresh the current nodes but do not advance the emitted
comparison. Manually printing a string or summary does not advance it either.

`device.get()` returns the complete current nodes, including states and hierarchy,
without another Device request. `activateApp`, `scrollTo` and `waitFor` also leave
a current observation available there. After a screenshot-only observation,
obtain fresh AX before using element indices.

## Platform differences

- Independent Devices can run concurrently; actions on one Device are sequential.
- `click` also accepts semantic text. iOS clicks are touch-only; use `longPress`
  for a context menu. `scroll` accepts fractional pages.
- `scrollTo` scrolls to semantic text using a visible anchor; `waitFor` checks
  a visible label's presence or absence. Use `device.help()` for these extensions.
- `setValue` replaces the whole editable value; `typeText` inserts at the cursor.
  `selectText` accepts `prefix`, `suffix` and `selectionType` to disambiguate.
  `pressKey` uses xdotool-style keys; `ctrl` and `super` are distinct.
- Rich-text paste, secondary AX actions and secure-text replacement/selection
  are unavailable. `paste` inserts plain text.
- Mac App lifecycle uses native `start --mac --app` / `stop -d mac`, not
  `listApps`, `activateApp`, `terminateApp` or Device `start()`.
  Mac currently supports single clicks and Return/Enter keys. After upgrading,
  restart the Mac App with the current build before using MCP text editing.

## Execution and recovery

Await the `js` result; no terminal polling or `ios-use repl` is needed.
`timeout_ms` defaults to 30,000 and can be raised to 300,000 for a longer action.
Ordinary JavaScript errors preserve the context. Timeout, cancellation and
`js_reset` clear variables and handles, but do not stop Drivers or Apps;
obtain a new Device handle afterward. Await work within the call.

Device errors include `category`, `retryable`, `mutationMayHaveApplied` and
`interaction`. If an action may already have applied, observe before retrying.
