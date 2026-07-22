import Foundation

enum CLIHelp {
    static var rootText: String {
        """
        Usage: ios-use [--help] [--version] <command>

        Swift CLI for ios-use.

        Options:
          -h, --help       Show help
          -V, --version    Show version

        Commands:
          status, config, start, stop, dom, waitFor, screenshot, capture, tap, longpress, input, swipe
          activateApp, terminateApp, home, open, dismissAlert, install, uninstall, apps, ddi-mount, proxy, oslog, nslog

        """
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
        case "status":
            return """
            Usage: ios-use status [--verbose] [--json]

            Show connected devices, capture processes, proxy state, and config state.

            Options:
              --verbose    Enable verbose device output
              --json       Print the common machine-readable envelope

            """
        case "config":
            return """
            Usage: ios-use config [--udid <udid>] [--simulator] [--list] [--apple-id <email>] [--password <password>] [--verbose]

            Configure a device or Simulator for ios-use.

            Options:
              --udid <udid>          Target device or Simulator UDID
              --simulator            Configure a Simulator
              --list                 List configured devices
              --apple-id <email>     Free Apple Developer account email for first-time real-device signing
              --password <password>  Developer account login password (prompted securely if omitted; 2FA code prompted separately if needed)
              --verbose              Enable verbose output

            """
        case "start":
            return """
            Usage: ios-use start [udid] [--verbose]

            Start the configured driver and record the active driver lock.
            Defaults to the first connected USB real device when udid is omitted.

            Options:
              --verbose    Enable verbose output

            """
        case "stop":
            return """
            Usage: ios-use stop

            Stop the active driver from driver.lock and clear the driver lock.

            """
        case "install":
            return """
            Usage: ios-use install <ipa|app> [--udid <udid>] [--verbose] [--json]

            Install a signed IPA or .app bundle on a USB real device using devicectl when available,
            with native AFC and installation_proxy fallback.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device UDID; overrides active driver.lock
              --verbose      Enable verbose output
              --json         Print the verified install receipt as JSON

            """
        case "uninstall":
            return """
            Usage: ios-use uninstall <bundleId> [--udid <udid>] [--verbose]

            Uninstall an app from a USB real device using installation_proxy.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device UDID; overrides active driver.lock
              --verbose      Print installation_proxy response frames

            """
        case "apps":
            return """
            Usage: ios-use apps [--udid <udid>] [--system] [--json]

            List apps installed on a USB real device using installation_proxy.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device UDID; overrides active driver.lock
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
                usage: "ios-use dom [--raw] [--fresh] [--wait-quiescence] [--ocr]",
                summary: "Print the current UI element tree.",
                options: [
                    "--raw               Print raw snapshot text; cannot be combined with other dom options",
                    "--fresh             Ignore cached snapshot and rebuild",
                    "--wait-quiescence   Wait until the UI is idle before returning a fresh DOM",
                    "--ocr               Also save a screenshot and return accurate OCR; implies a fresh DOM",
                ]
            )
        case "waitFor":
            return driverHelp(
                usage: "ios-use waitFor <target> [--timeout <duration>] [--match <mode>] [--traits <traits>] [--cindex <index>] [--gone]",
                summary: "Wait until an element appears or disappears.",
                options: [
                    "--label <label>      Legacy alternative to the positional target",
                    "--timeout <duration> Maximum wait, up to 300s; accepts s/ms suffixes and defaults to seconds",
                    "--match <mode>       contains (default; normalized exact preferred), exact, or regex",
                    "--traits <traits>    Comma-separated trait filter",
                    "--cindex <index>     Select the Nth cleaned child under a matched parent",
                    "--gone               Wait until no matching visible element remains",
                ],
                footer: "Use a stable substring for changing text, for example: ios-use waitFor '优化身形线条中' --gone --timeout 55s"
            )
        case "screenshot":
            return driverHelp(
                usage: "ios-use screenshot [--name <name>] [--no-ocr]",
                summary: "Save a screenshot under ios-use artifacts.",
                options: [
                    "--name <name>  Output name",
                    "--no-ocr       Skip host-side Vision OCR"
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
                summary: "Tap a label/value target. Coordinates are a fallback: ios-use tap 67,269 or ios-use tap 67 269.",
                options: [
                    "--offset <x,y>        Pixel offset from target top-left",
                    "--offset-ratio <x,y>  Ratio offset from target top-left",
                    "--traits <traits>     Comma-separated trait filter",
                    "--cindex <index>      Select the Nth cleaned child under a matched parent",
                    "--dom [duration]      Return a fresh DOM after the mutation; bare values default to ms; minimum 100ms",
                ]
            )
        case "longpress":
            return driverHelp(
                usage: "ios-use longpress <target> [--duration <duration>] [--traits <traits>] [--cindex <index>] [--dom [duration]]",
                summary: "Long press an element label or x,y coordinate.",
                options: [
                    "--duration <duration> Press duration; accepts s/ms suffixes and defaults to milliseconds",
                    "--traits <traits>  Comma-separated trait filter",
                    "--cindex <index>   Select the Nth cleaned child under a matched parent",
                    "--dom [duration]   Return a fresh DOM after the mutation; bare values default to ms; minimum 100ms",
                ]
            )
        case "input":
            return driverHelp(
                usage: "ios-use input [--tap <target>] --content <text> [--delete <n>] [--enter] [--traits <traits>] [--cindex <index>] [--dom [duration]]",
                summary: "Input text into the current keyboard focus, optionally tapping a target first.",
                options: [
                    "--tap <target>     Optional label or x,y target to tap before typing",
                    "--content <text>   Text to input",
                    "--delete <n>       Send n delete characters before content",
                    "--enter            Send a trailing newline, which may trigger Enter, Done, Go, or send",
                    "--traits <traits>  Comma-separated trait filter for label tap target",
                    "--cindex <index>   Select the Nth cleaned child under a label tap target",
                    "--dom [duration]   Return a fresh DOM after the mutation; bare values default to ms; minimum 100ms",
                ]
            )
        case "swipe":
            return driverHelp(
                usage: "ios-use swipe [--to <label>] [--from <label|x,y>] [--dir forth|back] [--distance <px>] [--traits <traits>] [--cindex <index>] [--dom [duration]]",
                summary: "Scroll toward a target or by a fixed distance.",
                options: [
                    "--to <label>       Target element",
                    "--from <label|x,y> Anchor element or coordinate",
                    "--dir forth|back   Fixed-distance direction",
                    "--distance <px>    Fixed distance in pixels",
                    "--traits <traits>  Comma-separated trait filter for --to",
                    "--cindex <index>   Select the Nth cleaned child under a matched --to parent",
                    "--dom [duration]   Return a fresh DOM after the mutation; bare values default to ms; minimum 100ms",
                ]
            )
        case "activateApp":
            return """
            Usage: ios-use activateApp <bundleId> [--udid <udid>] [--terminateExisting] [--log] [--dom | --no-wait] [--verbose] [--json]

            Activate an app by bundle ID using host-side device services.
            By default, waits for the app to reach foreground and for one fresh UI snapshot.
            With --log, starts a background app stdio capture and returns a log file path.

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

            Options:
              --udid <udid>  Target USB real device or booted Simulator UDID; overrides active driver.lock
              --verbose      Enable verbose output
              --json         Print the common machine-readable envelope

            """
        case "home":
            return driverHelp(
                usage: "ios-use home",
                summary: "Press the Home button."
            )
        case "open":
            return """
            Usage: ios-use open <url> [--udid <udid>] [--dom] [--verbose] [--json]

            Open a URL on the device using host-side device services.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device or booted Simulator UDID; overrides active driver.lock
              --dom          Return the first fresh DOM available after URL dispatch
              --verbose      Enable verbose output
              --json         Print the common machine-readable envelope

            """
        case "dismissAlert":
            return driverHelp(
                usage: "ios-use dismissAlert [--index <index>]",
                summary: "Dismiss a system alert.",
                options: ["--index <index>  Button index; defaults to the last button"]
            )
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
        return rootText
    }

    private static func commandHelpResult(_ arguments: [String]) -> CLIResult {
        guard let help = commandHelpText(arguments: arguments) else {
            let command = arguments.prefix { $0 != "--help" && $0 != "-h" }.joined(separator: " ")
            return CLIErrorEnvelope(message: "unknown command '\(command)'").render(help: rootText)
        }
        return CLIResult(exitCode: 0, stdout: help)
    }

    private static func driverHelp(usage: String, summary: String, options: [String] = [], footer: String? = nil) -> String {
        let renderedUsage = usage.contains("--json") ? usage : usage + " [--json]"
        var lines = [
            "Usage: \(renderedUsage)",
            "",
            summary,
            "",
            "Requires an active driver.lock. Run `ios-use start` first.",
        ]
        let renderedOptions = options + ["--json               Print the common machine-readable envelope"]
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
}
