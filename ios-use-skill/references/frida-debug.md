# Mac Frida Debug

Use this reference for an App started with Mac debugging enabled:

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

ios-use does not save script source. Variables, Interceptor hooks, and completed
side effects persist until App exit or an explicit reset. A script can change
state and then throw, so command failure does not imply rollback:

```bash
ios-use debug --reset
```

Reset starts a clean debug context and removes hooks installed through that
context. It cannot undo changes already made inside the App.

Own the restore path for every temporary App or native change. Before replacing
an implementation, return value, or App object state, capture what must be
restored and verify that restoration before leaving the workflow. If a safe
restore step cannot be stated, do not apply the change; `debug --reset` is not a
substitute for restoring App or native state.

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

For repeated work, save one script in the App's project instead of rebuilding it in
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

## Resolve APIs before attaching

Use Frida's resolver in the App and keep both the module and symbol patterns
narrow. This example searches the ExampleApp main module and caps displayed
matches:

```bash
ios-use debug - <<'JS'
const resolver = new ApiResolver('swift');
const matches = resolver.enumerateMatches(
  'functions:ExampleApp!*Feature*'
);
matches.slice(0, 20).map(match => ({
  name: match.name,
  address: match.address.toString()
}));
JS
```

Available resolver types and query shapes are:

- `swift`: `functions:<module-glob>!<symbol-glob>` for Swift functions.
- `module`: `exports:<module-glob>!<name-glob>`, `imports:...`, or
  `sections:...` for loaded modules.
- `objc`: `-[<class-glob> <selector-glob>]` or
  `+[<class-glob> <selector-glob>]` for Objective-C methods.

Append `/i` to a whole query for case-insensitive matching, for example
`functions:ExampleApp!*Feature*/i`. A resolver loads data lazily: reuse one resolver
instance for related queries in the same batch, and create a new instance for a
later batch so its view is current. The Swift and Objective-C resolvers are only
available when their runtimes are loaded; check `Swift.available` or
`ObjC.available`, or handle resolver construction failure.

Inspect every candidate's full name and signature before attaching; never
attach the first broad match automatically. Addresses are valid only for the
current App build and session.

If a resolver does not expose a known symbol, enumerate only its known owning
Module and use `DebugSymbol` to make the result readable:

```bash
ios-use debug - <<'JS'
const module = Process.mainModule;
const symbolSubstring = 'targetMethod'; // Replace with a reviewed substring.

module.enumerateSymbols()
  .filter(symbol => symbol.name.includes(symbolSubstring))
  .slice(0, 20)
  .map(symbol => ({
    mangled: symbol.name,
    name: DebugSymbol.fromAddress(symbol.address).name,
    address: symbol.address.toString(),
    offset: symbol.address.sub(module.base).toString()
  }));
JS
```

Review a candidate's signature and interception safety before attaching. If the
loaded Module is large, even one-module enumeration can exceed the 10-second
eval deadline; do not enumerate every process Module. If all three in-App paths
miss, the installed workflow cannot safely identify that symbol. Do not guess
an address or reuse symbols from another build.
