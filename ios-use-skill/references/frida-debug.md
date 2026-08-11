# Mac Frida Debug

Use this reference for an App started with the Mac backend; every Mac App
includes the Frida debug Engine, so `debug` is always available:

```bash
ios-use start --mac --app /path/to/App.app
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

## Pair Frida with a native dylib for complex UI patches

Keep the responsibility split simple:

- Frida is the control plane: inspect the current App, locate a route or runtime
  entry, load the native patch, invoke its lifecycle, and install only the small
  hooks needed to redirect into it.
- The dylib is the implementation plane: own substantial UIKit views, layout,
  animation, state, routing, delegates, data sources, and interaction logic.

Use GumJS alone for probes, observation, narrow return-value hooks, and changing
existing object properties. Use a native dylib for a new or replacement page,
regrouping tabs or tools, or any UI that is clearer as normal Swift or
Objective-C. The dylib may be compiled locally or remotely; it is not built
inside the running App and the Mac running ios-use does not need Xcode.

### Choose load-time application or an explicit entry point

Frida does not require a lifecycle protocol or any exported function. The
smallest one-shot patch applies itself from a C/Objective-C constructor or
Objective-C `+load`; `Module.load` runs those initializers while loading the
image. The initializer must dispatch UIKit work to the main thread and handle a
target page that may not exist yet. For a mostly Swift patch, use a tiny C or
Objective-C constructor shim instead of assuming Swift global initialization
runs eagerly.

Expose an explicit C-compatible apply function only when the Agent needs to
choose the application time, retry after navigation, or pass control separately
from loading. Swift patches can use `@_cdecl`; Objective-C/C patches can export
an ordinary C function:

```c
int32_t ios_use_patch_apply(void);
```

Make `apply` idempotent and perform UIKit mutation on the main thread. Add a
`restore` export only when same-process before/after comparison is valuable;
otherwise restart the App to discard the process-local patch. Add a `state`
export only for native work whose asynchronous or lazy installation cannot be
observed reliably through DOM and UI behavior. Do not turn either optional
function into a requirement for every patch.

Avoid UserDefaults, file, database, or remote writes in a runtime UI prototype.
Restarting the App or restoring its view hierarchy does not undo them.

Build the dylib for arm64 Mac Catalyst and make its native dependencies loadable
by dyld. When using explicit entry points, expose them as unmangled C symbols.
Dynamic lookup may resolve App or framework symbols already loaded in the
process, but it does not replace the Swift interfaces or headers required when
compiling the patch.

### Load and control the dylib through the existing debug command

`ios-use debug` already provides the required runtime primitive. Do not add a
separate CLI command merely to hide a short GumJS loader from an Agent. Reuse the
same loader template and load once per App process. For an auto-applying dylib,
loading is the whole operation:

```bash
ios-use debug - <<'JS'
(() => {
  const patch = globalThis.__iosUseNativePatch ??= {};
  patch.module ??= Module.load('/absolute/path/FeaturePatch.dylib');
  return { loaded: patch.module.name, base: patch.module.base.toString() };
})();
JS
```

If the patch intentionally exposes an explicit apply entry, bind and call it
after loading:

```bash
ios-use debug - <<'JS'
(() => {
  const patch = globalThis.__iosUseNativePatch ??= {};
  if (!patch.module) {
    patch.module = Module.load('/absolute/path/FeaturePatch.dylib');
    patch.apply = new NativeFunction(
      patch.module.getExportByName('ios_use_patch_apply'), 'int', []
    );
  }
  return { applyResult: patch.apply() };
})();
JS
```

Verify the active UI with `dom`, `ui-tree`, normal interactions, and a screenshot.
That UI evidence is the default state check.

If the patch intentionally exports `ios_use_patch_restore`, bind and call it in
the same way before resetting Frida. Otherwise restart the App to return to its
original process state:

```bash
ios-use stop
ios-use start --mac
```

Do not model native patching as load/unload. `debug --reset` removes Frida hooks
and the JS namespace, but it neither unloads the dylib nor reverses its native
mutations. For a rebuilt dylib, use its optional restore when available, stop and
restart the App, then apply the new build through the same `debug` workflow.

Do not expose symbol addresses, hashes, compiler flags, `Module.load`, or process
restart choreography to a non-RD user. The Agent owns those implementation
details and the patch-producing service owns compilation.
