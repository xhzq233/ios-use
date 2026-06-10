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
          devices, config, start, stop, dom, find, waitFor, screenshot, tap, longpress, input, swipe
          activateApp, terminateApp, home, open, dismissAlert, install, uninstall, apps, ddi-mount, flow, proxy, oslog, nslog

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
        case "devices", "device":
            return """
            Usage: ios-use devices [--simulator] [--verbose]

            List connected USB devices or booted Simulators.

            Options:
              -s, --simulator    List booted Simulators
              --verbose          Enable verbose output

            """
        case "config":
            return """
            Usage: ios-use config [--udid <udid>] [--simulator] [--list] [--apple-id <email>] [--password <password>] [--verbose]

            Configure a device or Simulator for ios-use.

            Options:
              --udid <udid>          Target device or Simulator UDID
              --simulator            Configure a Simulator
              --list                 List configured devices
              --apple-id <email>     Apple ID for first-time real-device signing
              --password <password>  App-specific password
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
            Usage: ios-use install <ipa|app> [--udid <udid>] [--verbose]

            Install a signed IPA or .app bundle on a USB real device using AFC and installation_proxy.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device UDID; overrides active driver.lock
              --verbose      Enable verbose output

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
                usage: "ios-use dom [--raw] [--fresh] [--wait-quiescence]",
                summary: "Print the current UI element tree.",
                options: [
                    "--raw               Print raw snapshot text; cannot be combined with other dom options",
                    "--fresh             Ignore cached snapshot and rebuild",
                    "--wait-quiescence   Wait until the UI is idle before returning a fresh DOM",
                ]
            )
        case "find":
            return driverHelp(
                usage: "ios-use find <label> [--traits <traits>] [--cindex <index>]",
                summary: "Find UI elements by label.",
                options: [
                    "--traits <traits>  Comma-separated trait filter",
                    "--cindex <index>   Select the Nth cleaned child under a matched parent",
                ]
            )
        case "waitFor":
            return driverHelp(
                usage: "ios-use waitFor --label <label> [--timeout <seconds>] [--traits <traits>] [--cindex <index>]",
                summary: "Wait until an element appears.",
                options: [
                    "--label <label>      Target label",
                    "--timeout <seconds>  Maximum wait time",
                    "--traits <traits>    Comma-separated trait filter",
                    "--cindex <index>     Select the Nth cleaned child under a matched parent",
                ]
            )
        case "screenshot":
            return driverHelp(
                usage: "ios-use screenshot [--name <name>]",
                summary: "Save a screenshot under ios-use artifacts.",
                options: ["--name <name>  Output name"]
            )
        case "tap":
            return driverHelp(
                usage: "ios-use tap <target> [--offset <x,y>] [--offset-ratio <x,y>] [--traits <traits>] [--cindex <index>] [--dom [ms]]",
                summary: "Tap an element label or x,y coordinate.",
                options: [
                    "--offset <x,y>        Pixel offset from target top-left",
                    "--offset-ratio <x,y>  Ratio offset from target top-left",
                    "--traits <traits>     Comma-separated trait filter",
                    "--cindex <index>      Select the Nth cleaned child under a matched parent",
                    "--dom [ms]            Return a fresh DOM after the mutation; without ms waits until UI is idle; ms must be >= 100",
                ]
            )
        case "longpress":
            return driverHelp(
                usage: "ios-use longpress <target> [--duration <ms>] [--traits <traits>] [--cindex <index>] [--dom [ms]]",
                summary: "Long press an element label or x,y coordinate.",
                options: [
                    "--duration <ms>   Press duration in milliseconds",
                    "--traits <traits>  Comma-separated trait filter",
                    "--cindex <index>   Select the Nth cleaned child under a matched parent",
                    "--dom [ms]         Return a fresh DOM after the mutation; without ms waits until UI is idle; ms must be >= 100",
                ]
            )
        case "input":
            return driverHelp(
                usage: "ios-use input [--tap <target>] --content <text> [--delete <n>] [--enter] [--traits <traits>] [--cindex <index>] [--dom [ms]]",
                summary: "Input text into the current keyboard focus, optionally tapping a target first.",
                options: [
                    "--tap <target>     Optional label or x,y target to tap before typing",
                    "--content <text>   Text to input",
                    "--delete <n>       Send n delete characters before content",
                    "--enter            Send a trailing newline, which may trigger Enter, Done, Go, or send",
                    "--traits <traits>  Comma-separated trait filter for label tap target",
                    "--cindex <index>   Select the Nth cleaned child under a label tap target",
                    "--dom [ms]         Return a fresh DOM after the mutation; without ms waits until UI is idle; ms must be >= 100",
                ]
            )
        case "swipe":
            return driverHelp(
                usage: "ios-use swipe [--to <label>] [--from <label|x,y>] [--dir forth|back] [--distance <px>] [--traits <traits>] [--cindex <index>] [--dom [ms]]",
                summary: "Scroll toward a target or by a fixed distance.",
                options: [
                    "--to <label>       Target element",
                    "--from <label|x,y> Anchor element or coordinate",
                    "--dir forth|back   Fixed-distance direction",
                    "--distance <px>    Fixed distance in pixels",
                    "--traits <traits>  Comma-separated trait filter for --to",
                    "--cindex <index>   Select the Nth cleaned child under a matched --to parent",
                    "--dom [ms]         Return a fresh DOM after the mutation; without ms waits until UI is idle; ms must be >= 100",
                ]
            )
        case "activateApp":
            return """
            Usage: ios-use activateApp <bundleId> [--udid <udid>] [--verbose]

            Activate an app by bundle ID using host-side device services.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device or booted Simulator UDID; overrides active driver.lock
              --verbose      Enable verbose output

            """
        case "terminateApp":
            return """
            Usage: ios-use terminateApp <bundleId> [--udid <udid>] [--verbose]

            Terminate an app by bundle ID using host-side device services.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device or booted Simulator UDID; overrides active driver.lock
              --verbose      Enable verbose output

            """
        case "home":
            return driverHelp(
                usage: "ios-use home",
                summary: "Press the Home button."
            )
        case "open":
            return """
            Usage: ios-use open <url> [--udid <udid>] [--verbose]

            Open a URL on the device using host-side device services.
            Defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>  Target USB real device or booted Simulator UDID; overrides active driver.lock
              --verbose      Enable verbose output

            """
        case "dismissAlert":
            return driverHelp(
                usage: "ios-use dismissAlert [--index <index>]",
                summary: "Dismiss a system alert.",
                options: ["--index <index>  Button index; defaults to the last button"]
            )
        case "flow":
            return """
            Usage: ios-use flow <file> [--verbose] [--<var> <value>...]

            Run a YAML flow.

            Options:
              --verbose       Enable verbose output
              --<var> <value> Pass an external flow variable

            """
        case "proxy":
            return proxyHelp(arguments: rest)
        case "oslog":
            return """
            Usage: ios-use oslog [--udid <udid>] [--process <name> | --pid <pid>] [--pattern <regex>] [--flags <flags>] [--timeout <seconds>] [--verbose]

            Stream OSLog output.
            Fetch defaults to the active driver.lock UDID when --udid is omitted.

            Options:
              --udid <udid>          Target device or Simulator UDID; overrides active driver.lock
              --process <name>       Filter by a single process/executable name
              --pid <pid>            Filter by a single process id
              --pattern <regex>      Regex filter
              --flags <flags>        Regex flags: i, m, s
              --timeout <seconds>    Collection or polling timeout; must be greater than 0
              --verbose              Enable verbose output

            """
        case "nslog":
            return """
            Usage: ios-use nslog [--name <name>]

            Forms:
              ios-use nslog [--name <name>]
              ios-use nslog start [--name <name>]
              ios-use nslog read [--pattern <regex>] [--flags <flags>] [--timeout <sec>] [--clearAfterRead] [--last N]
              ios-use nslog stop

            Stream or capture NSLogger logs.

            Options:
              --name <name>       Bonjour service name
              --pattern <regex>   Regex filter for nslog read
              --flags <flags>     Regex flags for nslog read: i, m, s
              --timeout <sec>     Wait for a matching line while capture is running
              --clearAfterRead    Truncate the capture log after reading
              --last N            Print only the last N matching lines (N > 0)

            """
        default:
            return nil
        }
    }

    private static func commandHelpResult(_ arguments: [String]) -> CLIResult {
        guard let help = commandHelpText(arguments: arguments) else {
            let command = arguments.prefix { $0 != "--help" && $0 != "-h" }.joined(separator: " ")
            return CLIErrorEnvelope(message: "unknown command '\(command)'").render()
        }
        return CLIResult(exitCode: 0, stdout: help)
    }

    private static func driverHelp(usage: String, summary: String, options: [String] = []) -> String {
        var lines = [
            "Usage: \(usage)",
            "",
            summary,
            "",
            "Requires an active driver.lock. Run `ios-use start` first.",
        ]
        if !options.isEmpty {
            lines += ["", "Options:"]
            lines += options.map { "  \($0)" }
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
              --raw                  Print full flow detail
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
