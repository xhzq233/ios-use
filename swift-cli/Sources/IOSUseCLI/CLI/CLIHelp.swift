import Foundation

enum CLIHelp {
    static var rootText: String {
        #if os(Linux)
        return """
        Usage: ios-use [--device <id>] <command>

        Linux remote client for iOS UI and Apple device services.
        Use a provider's device connection to start XCTest:
          ios-use start -d phone --connection device-connection.json
          ios-use status
          ios-use dom -d phone
          ios-use tap "<label>" -d phone --dom
          ios-use screenshot -d phone
          ios-use stop -d phone

        Commands: start, stop, status, dom, waitFor, screenshot, tap,
          longpress, input, swipe, apps, install, uninstall, open,
          activateApp, terminateApp, home, rotate, dismissAlert
        With multiple Devices, select one using -d <id>.
        Inspect current DOM before acting and keep page-dependent actions sequential.
        Use ios-use help <command> for options; --json returns structured results.
        Screenshots save the original JPEG and geometry. OCR requires macOS.
        The provider handles signing, Driver installation and transport setup.
        ios-use owns XCTest and activateApp --log for --connection sessions.

        """
        #else
        return """
        Usage: ios-use [--help] [--version] [--device <device-id>] <command>

        Control iOS apps on real devices, Simulators and Mac.

        Commands:
          Devices    status, config, start, stop
          Inspect    dom, screenshot, capture, ui-tree
          Interact   tap, longpress, input, swipe, waitFor, dismissAlert
          Apps       apps, activateApp, terminateApp, home, rotate, open
          Manage     install, uninstall, media, ddi-mount, du
          Diagnose   proxy, oslog, nslog, debug

        Options:
          -h, --help         Show help
          -V, --version      Show version
          -d, --device <id>  Use an ID from status; optional with one active target

        Example (with a running target):
          ios-use status
          ios-use dom -d <id>
          ios-use tap "<label-from-dom>" -d <id> --dom

        Details: ios-use help <command> or ios-use <command> --help

        """
        #endif
    }

    static func immediateResult(arguments: [String]) -> CLIResult? {
        guard let first = arguments.first else {
            return CLIResult(exitCode: 0, stdout: rootText)
        }
        switch first {
        case "-h", "--help":
            if arguments.count > 1 {
                return commandHelpResult(Array(arguments.dropFirst()))
            }
            return CLIResult(exitCode: 0, stdout: rootText)
        case "help":
            if arguments.count > 1 {
                return commandHelpResult(Array(arguments.dropFirst()))
            }
            return CLIResult(exitCode: 0, stdout: rootText)
        case "-V", "--version":
            return CLIResult(exitCode: 0, stdout: "\(IOSUseCLI.version)\n")
        default:
            guard arguments.dropFirst().contains("--help") || arguments.dropFirst().contains("-h") else {
                return nil
            }
            return commandHelpResult(arguments)
        }
    }

    static func commandHelpText(arguments: [String]) -> String? {
        guard let command = arguments.first else { return rootText }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "du":
            return """
            Usage: ios-use du [--json]

            Show ios-use-owned disk space grouped as rebuildable cache,
            persistent App data, IOS_USE_HOME data, and metadata/residue.
            The report includes cleanup impact, size, and last modification;
            --json includes raw paths, references, and warnings. This command
            is read-only and works without an active backend session.

            Options:
              --json       Print the common machine-readable envelope

            """
        case "status":
            return """
            Usage: ios-use status [--verbose] [--json]

            Show connected devices, capture processes, proxy state, config state,
            and read-only Mac backend resource/signer/session readiness.
            Session lifecycleOwner is ios-use for local and remote runtimes.
            Run dom to check remote responsiveness.

            Options:
              --verbose    Enable verbose device output
              --json       Print the common machine-readable envelope

            """
        case "config":
            return """
            Usage: ios-use config [--udid <udid>] [--simulator] [--list] [--verbose] [--json]
                   ios-use config --mac [--device-model <preset>] [--device-chrome on|off] [--window-mode fixed|resizable] [--verbose] [--json]

            Configure a device or Simulator, or explicitly initialize the
            dedicated stable Mac-backend signing identity.
            Run `config --mac` once before the first Mac backend start.
            `config --mac --device-model <preset>` only saves the device selection
            for the next cold start; it does not initialize signing or restart an App.
            Presets: iphone-se, iphone-13, iphone-15-pro, iphone-15-pro-max (default),
            ipad-pro-11, iphone-duo-inner (alias iphone-duo), iphone-duo-outer.
            Device chrome is on by default and is omitted from screenshots.
            `--window-mode resizable` preserves App scene size constraints and uses
            the current window size for DOM, touches and screenshots. Device screen
            identity stays fixed. This mode hides the device shell; use it to test
            adaptive iPad layouts, not to emulate the iPadOS window manager.
            These preferences apply on the next cold start.
            Duo presets are 3x layout previews based on App Store screenshot
            canvases; they retain the existing iPhone identity and do not emulate
            folding or iOS 27 UI. Stop, then start --mac to apply a change.
            macOS will show user authentication dialogs while the identity is
            created and trusted. If you cancel, safely retry the same command;
            the retry resumes the same signing identity instead of replacing it.
            `start --mac` never initializes or repairs this identity.
            Before first real-device signing, run this in a terminal:
              ~/.ios-use/altsign-cli/altsign-cli list --apple-id '<Apple ID>'
            AltSign reads the password and any two-factor code from standard
            input and stores one cached session.
            Then run `ios-use config --udid <udid>`.
            ios-use never reads credentials or inspects login state.

            Options:
              --udid <udid>          Target device or Simulator UDID
              --simulator            Configure a Simulator
              --list                 List configured devices
              --mac                  Initialize the dedicated stable Mac-backend signing identity
              --verbose              Enable verbose output
              --json                 Print the common machine-readable envelope

            """
        case "start":
            return """
            Usage: ios-use start [udid] [--verbose]
                   ios-use start [-d <id>] --connection <file> [--verbose]
                   ios-use start --mac --app <source.app> [--log] [--timeout <duration>]
                   ios-use start --mac [--log] [--timeout <duration>]

            Start a configured XCTest driver or an iOS App on this Mac and
            record it in that Device's context under IOS_USE_HOME.
            Defaults to the first connected USB real device when udid is omitted.
            With --connection, load a provider's JSON description containing
            udid, driverBundleID, usbmux {host, port} and driver {host, port}.
            The provider must install a signed Driver and establish paired
            device services. ios-use owns XCTest startup/stop, App management,
            open and activateApp --log on macOS and Linux. stop leaves the
            provider's transport and lease in place.
            Multiple Devices can run together. Use --device <device-id> on
            later commands; status prints the stable IDs.
            The Mac backend automatically prepares an unmodified iPhoneOS App
            into its account-global Bundle slot, or directly launches the
            current slot. The current IOS_USE_HOME stores only its selected
            Bundle ID and session state.
            Use --app after a source rebuild; ios-use reuses an unchanged
            installed slot automatically. Omit --app to launch this Home's
            current installed App.
            Every Mac App includes the resident Frida debug Engine.
            IOS_USE_PLAY_ENABLE_3X_BACKING=1 requests 3x scene backing for
            that Mac launch; omit it to let Catalyst choose the Retina backing.
            On macOS 26 or newer, start prints a compatibility warning and
            continues; Mac UI interaction is not fully supported and may crash.
            --log captures target-App stdout/stderr from the injected Runtime
            onward in an owner-only per-session file retained after stop,
            crash, or launch failure.

            Options:
              --connection <file>          Provider-established Apple device transport
              --verbose                    Enable verbose XCTest output
              --mac                        Select the Mac backend
              --app <source.app>            Install or update, then launch this App
              --log                        Capture target-App stdout/stderr to a retained session log
              --timeout <duration>          Runtime readiness timeout; default 60s

            """
        case "debug":
            return """
            Usage: ios-use debug [--stream] [--json] '<js>'
                   ios-use debug [--stream] [--json] -
                   ios-use debug --reset [--json]

            Evaluate JavaScript through the authenticated Runtime socket of the
            active Mac App's resident Frida Engine. Events are written to stderr and the
            final display value is written to stdout. Script source is not saved
            to disk, but Agent globals, hooks, and completed native mutations can
            remain active until debug --reset or App exit. A failed eval may have
            applied work before throwing; use debug --reset when a clean Agent is
            required. Reset clears Agent globals and hooks, not arbitrary App
            object or native-memory changes already made by the script.

            Options:
              --stream       Keep this connection open for events emitted after eval
              --reset        Clear the active Eval Agent globals and hooks
              --json         Print the common machine-readable envelope

            Read a multi-line script from stdin without placing it in argv:

              ios-use debug - <<'JS'
              console.log('ready');
              ({ pid: Process.id });
              JS

            Keep receiving callbacks installed by an eval until interrupted:

              ios-use debug --stream - <<'JS'
              const open = Module.getExportByName(null, 'open');
              Interceptor.attach(open, {
                onEnter(args) { console.log(args[0].readUtf8String()); }
              });
              'streaming';
              JS

            Terminate a stream to stop observing it, then run debug --reset to
            remove Agent-owned hooks before retrying or leaving the workflow.
            Keep explicit semicolons before a final object or parenthesized
            expression; otherwise JavaScript ASI can install a hook and then
            throw before its handle is saved.

            """
        case "stop":
            return """
            Usage: ios-use stop [-d <device-id>] [--json]

            Stop one XCTest driver or exact Mac process recorded in its
            Device Context. --device is required when multiple Devices run.

            Options:
              -d, --device Device ID printed by status
              --json       Print the common machine-readable envelope

            """
        case "install":
            return """
            Usage: ios-use install <ipa|app> [--udid <udid>] [--verbose] [--json]

            Install a signed IPA or .app bundle on a real device. Remote device
            connections use native AFC and installation_proxy; local macOS uses
            devicectl when available, with native fallback.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device UDID; overrides active driver.lock
              --verbose      Enable verbose output
              --json         Print the verified install receipt as JSON

            """
        case "uninstall":
            return """
            Usage: ios-use uninstall <bundleId> [--udid <udid>] [--verbose] [--json]

            Uninstall an app from a local or remote real device using installation_proxy.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device UDID; overrides active driver.lock
              --verbose      Print installation_proxy response frames

            """
        case "apps":
            return """
            Usage: ios-use apps [--udid <udid>] [--system] [--json]

            List apps installed on a USB real device or booted Simulator.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target real device or Simulator UDID; overrides active driver.lock
              --system       Include system apps
              --json         Print JSON

            """
        case "ddi-mount":
            return """
            Usage: ios-use ddi-mount [--udid <udid>] [--path <path>]

            Mount an iOS 17+ personalized Developer Disk Image on a USB real device.
            When --path is omitted, scans local CoreDevice DeveloperDiskImages caches.

            Options:
              --udid <udid>  Target USB real device UDID; defaults to active driver.lock or a single connected USB real device
              --path <path>  Restore directory, iOS_DDI directory, or iOS_DDI.dmg

            """
        case "dom":
            return driverHelp(
                usage: "ios-use dom [--raw] [--fresh] [--wait-quiescence]",
                summary: "Print the current UI element tree.",
                options: [
                    "--raw               Print raw snapshot text; cannot be combined with other dom options",
                    "--fresh             Ignore cached snapshot and rebuild",
                    "--wait-quiescence   Request UI-idle waiting, then refresh the tree",
                ],
                footer: """
                Use labels/values as action targets, not entire DOM lines. --dom on an action already returns an updated tree.
                Example: ios-use dom --fresh
                """
            )
        case "ui-tree":
            return """
            Usage: ios-use ui-tree [--target <semantic-target>] [--depth <0...20>] [--json]

            Inspect the current UIKit view hierarchy of the active Mac App.
            This is a read-only Mac-backend diagnostic for relating runtime
            views to source code. Use `dom` for stable UI interaction.
            Frames use each view's superview coordinate space; use `dom` for
            screen-level semantic geometry.

            Options:
              --target <semantic-target>  Inspect the UIView subtree backing one fresh DOM match
              --depth <0...20>            Maximum descendant depth; default 8
              --json                      Print the common machine-readable envelope

            Requires an active Mac session. It is not available for real
            devices or Simulators and never falls back to XCTest.

            """
        case "waitFor":
            return driverHelp(
                usage: "ios-use waitFor <target> [--timeout <duration>] [--match <mode>] [--traits <traits>] [--cindex <index>] [--gone]",
                summary: "Wait until an element appears or disappears.",
                options: [
                    "--label <label>      Legacy alternative to the positional target",
                    "--timeout <duration> Maximum wait, up to 300s; accepts s/ms suffixes and defaults to seconds",
                    "--match <mode>       contains (default; prefers exact matches), exact, or regex",
                    "--traits <traits>    Comma-separated trait filter",
                    "--cindex <index>     Select the Nth child under a matched parent",
                    "--gone               Wait until no matching visible element remains",
                ],
                footer: """
                App loading may continue after an action's --dom output. Wait for the label you need:
                  ios-use waitFor "通用" --timeout 10s
                Or wait for an observed loading message to disappear, matching its stable text:
                  ios-use waitFor "Loading" --match contains --gone --timeout 20s
                """
            )
        case "screenshot":
            return driverHelp(
                usage: "ios-use screenshot [--name <name>] [--ocr | --no-ocr]",
                summary: "Save a screenshot under ios-use artifacts. OCR is off by default.",
                options: [
                    "--name <name>  Output name",
                    "--ocr          Enable host-side Vision OCR (macOS only)",
                    "--no-ocr       Skip OCR (default; retained for compatibility)"
                ]
            )
        case "capture":
            return """
            Usage: ios-use capture [--duration <duration>] [--fps <number>] [--name <name>] [--keep-changed-frames]

            Capture a short sequence of JPEG screenshots for AI inspection.
            The output is a directory containing images and manifest.json; no video or GIF is produced.
            Run a tap first when a capture should start immediately after an interaction.

            Options:
              --duration <duration>     Capture duration; accepts s/ms suffixes, defaults to 3s
              --fps <number>            Sampling rate in (0, 10]; defaults to 10
              --name <name>             Artifact directory name
              --keep-changed-frames     Keep only visually changed frames (tolerant Logical-size tile diff)

            Requires an active driver.lock. Run `ios-use start` first.

            """
        case "tap":
            return driverHelp(
                usage: "ios-use tap <target> [--offset <x,y>] [--offset-ratio <x,y>] [--traits <traits>] [--cindex <index>] [--dom [duration]]",
                summary: "Tap a label/value from DOM, or a coordinate such as 67,269.",
                options: [
                    "--offset <x,y>        Pixel offset from target top-left",
                    "--offset-ratio <x,y>  Ratio offset from target top-left",
                    "--traits <traits>     Comma-separated trait filter",
                    "--cindex <index>      Select the Nth child under a matched parent",
                    postDOMOption,
                ],
                footer: """
                Examples:
                  ios-use tap "通用" --dom
                  ios-use tap "亮度" --offset-ratio 0.8,0.5 --dom
                """
            )
        case "longpress":
            return driverHelp(
                usage: "ios-use longpress <target> [--duration <duration>] [--traits <traits>] [--cindex <index>] [--dom [duration]]",
                summary: "Long press an element label or x,y coordinate.",
                options: [
                    "--duration <duration> Press duration; accepts s/ms suffixes and defaults to milliseconds",
                    "--traits <traits>  Comma-separated trait filter",
                    "--cindex <index>   Select the Nth child under a matched parent",
                    postDOMOption,
                ],
                footer: "Example: ios-use longpress \"照片\" --duration 800ms --dom"
            )
        case "input":
            return driverHelp(
                usage: "ios-use input [--tap <target>] --content <text> [--delete <n>] [--enter] [--traits <traits>] [--cindex <index>] [--dom [duration]]",
                summary: "Insert text at the cursor; existing text is not replaced automatically.",
                options: [
                    "--tap <target>     Optional label or x,y target to tap before typing",
                    "--content <text>   Text to insert",
                    "--delete <n>       Send n delete characters before content",
                    "--enter            Send a trailing newline, which may trigger Enter, Done, Go, or send",
                    "--traits <traits>  Comma-separated trait filter for label tap target",
                    "--cindex <index>   Select the Nth child under a label tap target",
                    postDOMOption,
                ],
                footer: "Example: ios-use input --tap \"搜索\" --content \"蓝牙\" --dom"
            )
        case "swipe":
            return driverHelp(
                usage: "ios-use swipe [--to <label>] [--from <label|x,y>] [--dir forth|back] [--distance <px>] [--traits <traits>] [--cindex <index>] [--dom [duration]]",
                summary: "Scroll to a DOM label, or use a fixed distance when no label is available.",
                options: [
                    "--to <label>       Target element",
                    "--from <label|x,y> Anchor element or coordinate",
                    "--dir forth|back   Fixed-distance direction",
                    "--distance <px>    Fixed distance in pixels",
                    "--traits <traits>  Comma-separated trait filter for --to",
                    "--cindex <index>   Select the Nth child under a matched --to parent",
                    postDOMOption,
                ],
                footer: """
                Use the target's exact label and a visible anchor in the same list or panel:
                  ios-use swipe --to "开发者" --from "蓝牙" --dom
                Without a labeled target:
                  ios-use swipe --dir forth --distance 300 --dom
                """
            )
        case "activateApp":
            return """
            Usage: ios-use activateApp <bundleId> [--udid <udid>] [--terminateExisting] [--log] [--dom | --no-wait] [--verbose] [--json]

            Activate an app by bundle ID using host-side device services.
            By default, waits for the app to reach foreground and for one fresh UI snapshot.
            With --log, starts background App stdout/stderr capture on the CLI host.
            Files are retained under IOS_USE_HOME/logs/devices/<device-id>/;
            --json returns data.logFile and data.logCapturePid.
            The Mac backend supports lifecycle through start/status/stop only;
            restart it with stop, then start --mac.

            Options:
              --udid <udid>          Target USB real device or booted Simulator UDID; overrides active driver.lock
              --terminateExisting    Relaunch the app instead of activating an existing process
              --log                  Capture stdout/stderr; requires --terminateExisting
              --dom                  Return the fresh DOM already obtained by readiness
              --no-wait              Return after host launch dispatch without contacting the Driver
              --verbose              Enable verbose output
              --json                 Print the common machine-readable envelope

            """
        case "terminateApp":
            return """
            Usage: ios-use terminateApp <bundleId> [--udid <udid>] [--verbose] [--json]

            Terminate an app by bundle ID using host-side device services.
            Defaults to the active driver.lock UDID when --udid is omitted.
            The Mac backend supports lifecycle through start/status/stop only;
            stop the active Mac session instead.

            Options:
              --udid <udid>  Target USB real device or booted Simulator UDID; overrides active driver.lock
              --verbose      Enable verbose output
              --json         Print the common machine-readable envelope

            """
        case "home":
            return driverHelp(
                usage: "ios-use home",
                summary: "Press the Home button.",
                footer: "The Mac backend has no Home action. Use start/status/stop; restart it with stop, then start --mac."
            )
        case "rotate":
            return driverHelp(
                usage: "ios-use rotate --to <orientation> [--dom [duration]]",
                summary: "Rotate the device and verify the resulting orientation.",
                options: [
                    "--to <orientation>  portrait, portrait-upside-down, landscape-left, or landscape-right",
                    postDOMOption,
                ],
                footer: "An orientation-locked App may keep its layout. Not supported on the Mac backend."
            )
        case "open":
            return """
            Usage: ios-use open <url> [--bundle-id <bundleId>] [--udid <udid>] [--dom] [--verbose] [--json]

            Open a URL on the device using host-side device services.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --bundle-id <bundleId>  Deliver the URL to this App without terminating its running instance
              --udid <udid>  Target USB real device or booted Simulator UDID; overrides active driver.lock
              --dom          Return the first fresh DOM available after URL dispatch
              --verbose      Enable verbose output
              --json         Print the common machine-readable envelope

            Explicit App delivery supports local and remote real devices. On the Mac
            backend, the bundle ID must match the active App. Simulator supports only
            system URL routing (omit --bundle-id). Without --bundle-id, real devices
            retain system routing and the Mac backend uses its active App.
            --dom waits for the specified App when given; it does not prove that the
            deep-link destination has finished loading. Custom schemes must be
            registered by the target App; HTTP(S) delivery is decided by the OS.

            """
        case "dismissAlert":
            return driverHelp(
                usage: "ios-use dismissAlert [--index <index> | --label <label> | --primary | --only-button] [--scope springboard|app|any] [--wait <duration>]",
                summary: "Dismiss an alert only when its button selection is explicit or unambiguous.",
                options: [
                    "--index <index>          Select the exact XCTest query-result index",
                    "--label <label>          Select one exact normalized button label",
                    "--primary                Select the visual trailing/top button heuristic",
                    "--only-button            Require exactly one hittable button; this is the default",
                    "--scope <scope>           springboard, app, or any; defaults to any",
                    "--wait <duration>         Bounded alert wait; defaults to 0 (one check), maximum 30s",
                ]
            )
        case "media":
            return mediaHelp(arguments: rest)
        case "oslog":
            return """
            Usage: ios-use oslog [--udid <udid>] [--process <name> | --pid <pid>] [--pattern <regex>] [--flags <flags>] [--timeout <duration>] [--verbose]

            Stream OSLog output.
            Fetch defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>          Target device or Simulator UDID; overrides active driver.lock
              --process <name>       Filter by a single process/executable name
              --pid <pid>            Filter by a single process id
              --pattern <regex>      Regex filter
              --flags <flags>        Regex flags: i, m, s
              --timeout <duration>   Collection or polling timeout; accepts s/ms suffixes and defaults to seconds
              --verbose              Enable verbose output

            """
        case "nslog":
            return """
            Usage: ios-use nslog [--name <name>]

            Forms:
              ios-use nslog [--name <name>]
              ios-use nslog start [--name <name>]
              ios-use nslog read [--pattern <regex>] [--flags <flags>] [--timeout <duration>] [--clearAfterRead] [--last N]
              ios-use nslog stop

            Stream or capture NSLogger logs.

            Options:
              --name <name>       Bonjour service name
              --pattern <regex>   Regex filter for nslog read
              --flags <flags>     Regex flags for nslog read: i, m, s
              --timeout <duration> Wait for a matching line; accepts s/ms suffixes and defaults to seconds
              --clearAfterRead    Truncate the capture log after reading
              --last N            Print only the last N matching lines (N > 0)

            """
        case "proxy":
            return proxyHelp(arguments: rest)
        default:
            return nil
        }
    }

    static func parseErrorHelp(arguments: [String]) -> String {
        if let help = commandHelpText(arguments: arguments) {
            return help
        }
        if arguments.first == "proxy",
           let help = commandHelpText(arguments: ["proxy"]) {
            return help
        }
        if arguments.first == "media",
           let help = commandHelpText(arguments: ["media"]) {
            return help
        }
        return rootText
    }

    private static func commandHelpResult(_ arguments: [String]) -> CLIResult {
        guard let help = commandHelpText(arguments: arguments) else {
            let command = arguments.prefix { $0 != "--help" && $0 != "-h" }.joined(separator: " ")
            return CLIErrorEnvelope(message: "unknown command '\(command)'").render(help: rootText)
        }
        return CLIResult(exitCode: 0, stdout: help)
    }

    private static let postDOMOption = "--dom [duration]      Return updated UI; bare flag waits for idle, value sets a fixed delay (ms/s; default ms; min 100ms)"

    private static func driverHelp(usage: String, summary: String, options: [String] = [], footer: String? = nil) -> String {
        let renderedUsage = usage.contains("--json") ? usage : usage + " [--json]"
        var lines = [
            "Usage: \(renderedUsage)",
            "",
            summary,
            "",
            "Requires an active target; see `ios-use status`.",
        ]
        let renderedOptions = options + [
            "-d, --device <id>     Select a running Device; optional when only one runs",
            "--json               Print JSON",
        ]
        if !renderedOptions.isEmpty {
            lines += ["", "Options:"]
            lines += renderedOptions.map { "  \($0)" }
        }
        if let footer {
            lines += ["", footer]
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func proxyHelp(arguments: [String]) -> String? {
        let subcommand = arguments.first { $0 != "--help" && $0 != "-h" }
        switch subcommand {
        case nil:
            return """
            Usage: ios-use proxy <command>

            Manage HTTP/HTTPS proxy capture.

            Commands:
              configca    Install and trust the mitmproxy CA on the device
              start       Start capture and configure Wi-Fi proxy
              read        Read the most recent capture
              stop        Clear Wi-Fi proxy and stop capture
              doctor      Check local proxy prerequisites

            """
        case "configca":
            return """
            Usage: ios-use proxy configca [--mark-trusted]

            Install and trust the mitmproxy CA on the device.
            If iOS requires manual passcode/trust steps, finish them on the device
            and then run with --mark-trusted to record manual confirmation.

            Requires an active driver.lock. Run `ios-use start` first.

            Options:
              --mark-trusted    Record that the current CA was manually trusted

            """
        case "start":
            return """
            Usage: ios-use proxy start [--server] [-i <interface>]

            Start mitmdump and configure the device Wi-Fi proxy.
            With --server, only start the local mitmdump server and record last capture.

            Requires an active driver.lock unless --server is used.

            Options:
              -i, --interface <name>    Network interface to advertise
              --server                  Start only the local mitmdump server

            """
        case "stop":
            return """
            Usage: ios-use proxy stop [--server]

            Clear the device Wi-Fi proxy and stop capture.
            With --server, only stop the local mitmdump server.

            Requires an active driver.lock unless --server is used.

            Options:
              --server    Stop only the local mitmdump server

            """
        case "read":
            return """
            Usage: ios-use proxy read [--filter <expression>] [--raw] [--last N]

            Read the most recent mitmdump capture recorded by proxy start.
            Does not require a running Device.

            Options:
              --filter <expression>  mitmdump filter expression
              --raw                  Print full capture detail
              --last N               Print only the last N output lines (N > 0)

            """
        case "doctor":
            return """
            Usage: ios-use proxy doctor

            Check local proxy prerequisites and current proxy state.

            """
        default:
            return nil
        }
    }

    private static func mediaHelp(arguments: [String]) -> String? {
        let subcommand = arguments.first { $0 != "--help" && $0 != "-h" }
        switch subcommand {
        case nil:
            return """
            Usage: ios-use media <command>

            Add local media to the connected device through the active Driver.

            Commands:
              import    Add one photo or video to the device Photos library

            """
        case "import":
            return """
            Usage: ios-use media import <photo-or-video> [--json]

            Add one local photo or video to the device Photos library.
            The first import requests Photos add-only access and safely accepts
            the newly caused Runner permission prompt when it is unambiguous.

            Requires an active driver.lock. Run `ios-use start` first.
            Use an ordinary shell loop to import multiple files.

            Options:
              --json    Print the common machine-readable envelope

            """
        default:
            return nil
        }
    }
}
