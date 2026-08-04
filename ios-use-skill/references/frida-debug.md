# Mac Frida Debug

Use this reference only for an App started by the experimental Mac backend with
the optional in-process Frida Engine:

```bash
ios-use start --mac --frida --app /path/to/App.app
```

## Run scripts

Pass multi-line GumJS through stdin:

```bash
ios-use debug - <<'JS'
console.log('ready');
({ pid: Process.id, module: Process.mainModule.name });
JS
```

Use `--json` when another tool needs the result and structured error fields:

```bash
ios-use debug --json - <<'JS'
({ threads: Process.enumerateThreads().length });
JS
```

Normal eval collects events produced before the script settles. Use
`--stream` when hooks must keep reporting later events. The command stays open
until interrupted, and only one stream can own the App at a time:

```bash
ios-use debug --stream - <<'JS'
const open = Module.getExportByName(null, 'open');
Interceptor.attach(open, {
  onEnter(args) { console.log(args[0].readUtf8String()); }
});
'streaming';
JS
```

ios-use does not save script source. Agent globals, Interceptor hooks, and other
completed side effects do persist until App exit or an explicit reset. A script
can change state and then throw, so command failure does not imply rollback:

```bash
ios-use debug --reset
```

Reset reloads the Agent and clears Agent-owned globals and hooks. It cannot undo
arbitrary changes already made to App objects or native memory.

Always terminate statements explicitly before a final object or parenthesized
expression. JavaScript automatic semicolon insertion can otherwise turn this:

```javascript
globalThis.probe = Interceptor.attach(address, callbacks)
({ attached: true })
```

into a call on the attach result. The hook may already be installed while the
assignment of its handle never completes. If attach or eval reports an error,
run `ios-use debug --reset` before attaching again unless preserving the
partially changed state is intentional.

For repeated work, keep one project-owned script instead of rebuilding it in
shell history. Make installation idempotent, keep one namespace, and detach the
previous handle before replacing it. This example hooks a reviewed C export;
Swift symbol discovery is covered separately below:

```javascript
const state = globalThis.__iosUseProbe ??= {};
state.handle?.detach();

const address = Module.getExportByName(null, 'open');
state.handle = Interceptor.attach(address, {
  onEnter(args) {
    state.calls = (state.calls ?? 0) + 1;
    console.log(`open calls=${state.calls} path=${args[0].readUtf8String()}`);
  }
});
({ attached: true, address: address.toString() });
```

Run it with `ios-use debug --stream - < probe.js`, exercise the App from a
second terminal, interrupt the stream, then run `ios-use debug --reset`.
Interrupting the stream closes observation; it does not remove the hook.

## Find Swift symbols

Try the Swift resolver first and keep the query narrow:

```bash
ios-use debug - <<'JS'
const resolver = new ApiResolver('swift');
const matches = resolver.enumerateMatches(
  'functions:*IOSUsePlayFixture*!*FixtureHostingController.overrides*'
);
if (matches.length === 0) throw new Error('fixture resolver target was not found');

// Fixture-only attachability smoke: install one no-op callback, then detach it
// without invoking the compiler-generated target.
const handle = Interceptor.attach(matches[0].address, { onEnter() {} });
handle.detach();
({ name: matches[0].name, address: matches[0].address.toString(), detached: true });
JS
```

Swift resolver queries always have the form `functions:<module>!<symbol>`.
Replace both patterns for the App under test, inspect every candidate's
signature, and do not automatically attach the first match in business code.
The resolver is fast but does not expose every Swift symbol. If it misses a
known method, enumerate only the owning loaded Module, filter the mangled names,
then ask `DebugSymbol` for readable names:

```bash
ios-use debug - <<'JS'
const module = Process.enumerateModules()
  .find(candidate => candidate.name === 'IOSUsePlayFixture');
if (module === undefined) throw new Error('module is not loaded');

module.enumerateSymbols()
  .filter(symbol => symbol.name.includes('recordProbe'))
  .slice(0, 20)
  .map(symbol => ({
    mangled: symbol.name,
    name: DebugSymbol.fromAddress(symbol.address).name,
    address: symbol.address.toString(),
    offset: symbol.address.sub(module.base).toString()
  }));
JS
```

Review a candidate's signature and interception safety before attaching. Live
addresses and offsets are valid only for the current App build and session. If
the loaded Module is large, even one-module enumeration can exceed the 10-second
eval deadline; do not enumerate every process Module. If that Module is stripped
or both Runtime methods miss, inspect the exact matching binary/dSYM with host
tools; do not reuse symbols from another build.
