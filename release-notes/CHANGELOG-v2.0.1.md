# ios-use v2.0.1

## Highlights

- `ios-use start --mac --app <source.app>` now installs or updates one current
  App per Bundle ID, while `--reuse` launches that current installation.
- Every Mac App includes the resident Frida debug Engine, so `ios-use debug`
  works without a separate start option.
- Mac Apps now preserve native Catalyst platform identity so Apple UI
  frameworks initialize reliably on macOS 26, while retaining the iPhone
  device profile, hiding launch-only environment values, and reporting common
  jailbreak filesystem probes as absent.
- Interrupted Mac launches can now be retried or stopped without leaving an
  unresolved session that blocks the next start.
- Release downloads are reduced to the CLI, two driver IPAs, one Mac resource
  archive, and their checksum manifest.

## Breaking Behavior

- Removed the `start --mac --frida` option. Frida is no longer selectable or
  assertable per start; drop `--frida` from existing `start --mac --app` and
  `start --mac --reuse` invocations.
- The previous Mac App cache is not migrated. After upgrading, use
  `start --mac --app <source.app>` once for each Bundle ID before using
  `--reuse`.

## Notes

- `ios-use debug`, `--reset`, and `--stream` are unchanged and continue to use
  the resident in-process GumJS Agent over the authenticated Runtime socket.
- This release does not attempt to hide native Catalyst identity, loaded
  Runtime/Frida images, or provide generic anti-debug behavior.
