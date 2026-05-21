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
          devices, config, dom, find, waitFor, screenshot, tap, longpress, input, swipe
          activateApp, terminateApp, home, open, dismissAlert, flow, proxy, oslog, nslog

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
        case "stop":
            return """
            Usage: ios-use stop

            Stop the active driver session.

            """
        case "dom":
            return driverHelp(
                usage: "ios-use dom [--raw] [--fresh] [--udid <udid>] [--verbose]",
                summary: "Print the current UI element tree.",
                options: [
                    "--raw        Print raw snapshot text",
                    "--fresh      Ignore cached snapshot and rebuild",
                ]
            )
        case "find":
            return driverHelp(
                usage: "ios-use find <label> [--traits <traits>] [--cindex <index>] [--udid <udid>] [--verbose]",
                summary: "Find UI elements by label.",
                options: [
                    "--traits <traits>  Comma-separated trait filter",
                    "--cindex <index>   Select the Nth cleaned child under a matched parent",
                ]
            )
        case "waitFor":
            return driverHelp(
                usage: "ios-use waitFor --label <label> [--timeout <seconds>] [--traits <traits>] [--cindex <index>] [--udid <udid>] [--verbose]",
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
                usage: "ios-use screenshot [--name <name>] [--udid <udid>] [--verbose]",
                summary: "Save a screenshot under ios-use artifacts.",
                options: ["--name <name>  Output name"]
            )
        case "tap":
            return driverHelp(
                usage: "ios-use tap <target> [--offset <x,y>] [--offset-ratio <x,y>] [--traits <traits>] [--cindex <index>] [--udid <udid>] [--verbose]",
                summary: "Tap an element label or x,y coordinate.",
                options: [
                    "--offset <x,y>        Pixel offset from target top-left",
                    "--offset-ratio <x,y>  Ratio offset from target top-left",
                    "--traits <traits>     Comma-separated trait filter",
                    "--cindex <index>      Select the Nth cleaned child under a matched parent",
                ]
            )
        case "longpress":
            return driverHelp(
                usage: "ios-use longpress <target> [--duration <ms>] [--traits <traits>] [--cindex <index>] [--udid <udid>] [--verbose]",
                summary: "Long press an element label or x,y coordinate.",
                options: [
                    "--duration <ms>   Press duration in milliseconds",
                    "--traits <traits>  Comma-separated trait filter",
                    "--cindex <index>   Select the Nth cleaned child under a matched parent",
                ]
            )
        case "input":
            return driverHelp(
                usage: "ios-use input --label <label> --content <text> [--traits <traits>] [--cindex <index>] [--udid <udid>] [--verbose]",
                summary: "Input text into a field.",
                options: [
                    "--label <label>    Target field label",
                    "--content <text>   Text to input",
                    "--traits <traits>  Comma-separated trait filter",
                    "--cindex <index>   Select the Nth cleaned child under a matched parent",
                ]
            )
        case "swipe":
            return driverHelp(
                usage: "ios-use swipe [--to <label>] [--from <label|x,y>] [--dir forth|back] [--distance <px>] [--traits <traits>] [--cindex <index>] [--udid <udid>] [--verbose]",
                summary: "Scroll toward a target or by a fixed distance.",
                options: [
                    "--to <label>       Target element",
                    "--from <label|x,y> Anchor element or coordinate",
                    "--dir forth|back   Fixed-distance direction",
                    "--distance <px>    Fixed distance in pixels",
                    "--traits <traits>  Comma-separated trait filter for --to",
                    "--cindex <index>   Select the Nth cleaned child under a matched --to parent",
                ]
            )
        case "activateApp":
            return driverHelp(
                usage: "ios-use activateApp <bundleId> [--udid <udid>] [--verbose]",
                summary: "Activate an app by bundle ID."
            )
        case "terminateApp":
            return driverHelp(
                usage: "ios-use terminateApp <bundleId> [--udid <udid>] [--verbose]",
                summary: "Terminate an app by bundle ID."
            )
        case "home":
            return driverHelp(
                usage: "ios-use home [--udid <udid>] [--verbose]",
                summary: "Press the Home button."
            )
        case "open":
            return driverHelp(
                usage: "ios-use open <url> [--udid <udid>] [--verbose]",
                summary: "Open a URL on the device."
            )
        case "dismissAlert":
            return driverHelp(
                usage: "ios-use dismissAlert [--index <index>] [--udid <udid>] [--verbose]",
                summary: "Dismiss a system alert.",
                options: ["--index <index>  Button index; defaults to the last button"]
            )
        case "flow":
            return """
            Usage: ios-use flow <file> [--udid <udid>] [--verbose] [--<var> <value>...]

            Run a YAML flow.

            Options:
              --udid <udid>   Target device or Simulator UDID
              --verbose       Enable verbose output
              --<var> <value> Pass an external flow variable

            """
        case "proxy":
            return proxyHelp(arguments: rest)
        case "oslog":
            return """
            Usage: ios-use oslog [--udid <udid>] [--pattern <regex>] [--flags <flags>] [--timeout <seconds>] [--name <name>] [--bundle-id <bundleId>] [--clear] [--verbose]

            Fetch or clear OSLog output.

            Options:
              --udid <udid>          Target device or Simulator UDID
              --pattern <regex>      Regex filter
              --flags <flags>        Regex flags: i, m, s
              --timeout <seconds>    Collection or polling timeout
              --name <name>          Output artifact name
              --bundle-id <bundleId> Filter by bundle ID
              --clear                Clear buffered oslog lines
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
            "Common options:",
            "  --udid <udid>  Target device or Simulator UDID",
            "  --verbose      Enable verbose output",
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
            Usage: ios-use proxy configca [--udid <udid>]

            Install and trust the mitmproxy CA on the device.

            Options:
              --udid <udid>  Target device or Simulator UDID

            """
        case "start":
            return """
            Usage: ios-use proxy start [--udid <udid>] [-i <interface>]

            Start mitmdump and configure the device Wi-Fi proxy.

            Options:
              --udid <udid>             Target device or Simulator UDID
              -i, --interface <name>    Network interface to advertise

            """
        case "stop":
            return """
            Usage: ios-use proxy stop [--udid <udid>]

            Clear the device Wi-Fi proxy and stop capture.

            Options:
              --udid <udid>  Target device or Simulator UDID

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
