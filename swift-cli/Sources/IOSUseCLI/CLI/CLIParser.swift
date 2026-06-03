import Foundation

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> ParsedCommand {
        var parser = ArgumentParser(arguments)
        guard let command = parser.consume() else {
            throw CLIParseError.missingCommand
        }

        switch command {
        case "devices", "device":
            return .devices(try parseDevices(&parser))
        case "config":
            return .config(try parseConfig(&parser))
        case "start":
            return .start(try parseStart(&parser))
        case "stop":
            try parser.requireEnd()
            return .stop
        case "install":
            return .install(try parseInstall(&parser))
        case "uninstall":
            return .uninstall(try parseUninstall(&parser))
        case "apps":
            return .apps(try parseApps(&parser))
        case "flow":
            return .flow(try parseFlow(&parser))
        case "nslog":
            return .nslog(try parseNSLog(&parser))
        case "proxy":
            return .proxy(try parseProxy(&parser))
        case "tap":
            return .driver(try parseTap(&parser))
        case "longpress":
            return .driver(try parseLongPress(&parser))
        case "input":
            return .driver(try parseInput(&parser))
        case "swipe":
            return .driver(try parseSwipe(&parser))
        case "dom":
            return .driver(try parseDom(&parser))
        case "find":
            return .driver(try parseFind(&parser))
        case "screenshot":
            return .driver(try parseScreenshot(&parser))
        case "waitFor":
            return .driver(try parseWaitFor(&parser))
        case "activateApp":
            return .driver(try parseBundleAction(&parser, kind: .activateApp))
        case "terminateApp":
            return .driver(try parseBundleAction(&parser, kind: .terminateApp))
        case "home":
            return .driver(try parseHome(&parser))
        case "open":
            return .open(try parseOpen(&parser))
        case "dismissAlert":
            return .driver(try parseDismissAlert(&parser))
        case "oslog":
            return .oslog(try parseOSLog(&parser))
        default:
            throw CLIParseError.unknownCommand(command)
        }
    }

    private static func parseDevices(_ parser: inout ArgumentParser) throws -> DeviceOptions {
        var options = DeviceOptions()
        while let arg = parser.consume() {
            switch arg {
            case "-s", "--simulator": options.simulator = true
            case "--verbose": options.verbose = true
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return options
    }

    private static func parseConfig(_ parser: inout ArgumentParser) throws -> ConfigOptions {
        var options = ConfigOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--udid": options.udid = try parser.value(for: arg)
            case "--list": options.list = true
            case "--simulator": options.simulator = true
            case "--apple-id": options.appleId = try parser.value(for: arg)
            case "--password": options.password = try parser.value(for: arg)
            case "--verbose": options.verbose = true
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return options
    }

    private static func parseStart(_ parser: inout ArgumentParser) throws -> StartOptions {
        let udid = try parser.requiredPositional("udid")
        var options = StartOptions(udid: udid)
        while let arg = parser.consume() {
            switch arg {
            case "--verbose": options.verbose = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.unknownOption(arg)
                }
                throw CLIParseError.unexpectedArgument(arg)
            }
        }
        return options
    }

    private static func parseInstall(_ parser: inout ArgumentParser) throws -> AppInstallOptions {
        let ipaPath = try parser.requiredPositional("ipa")
        var udid: String?
        var verbose = false
        while let arg = parser.consume() {
            switch arg {
            case "--udid": udid = try parser.value(for: arg)
            case "--verbose": verbose = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.unknownOption(arg)
                }
                throw CLIParseError.unexpectedArgument(arg)
            }
        }
        return AppInstallOptions(ipaPath: ipaPath, udid: udid, verbose: verbose)
    }

    private static func parseUninstall(_ parser: inout ArgumentParser) throws -> AppUninstallOptions {
        let bundleID = try parser.requiredPositional("bundleId")
        var udid: String?
        var verbose = false
        while let arg = parser.consume() {
            switch arg {
            case "--udid": udid = try parser.value(for: arg)
            case "--verbose": verbose = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.unknownOption(arg)
                }
                throw CLIParseError.unexpectedArgument(arg)
            }
        }
        return AppUninstallOptions(bundleID: bundleID, udid: udid, verbose: verbose)
    }

    private static func parseApps(_ parser: inout ArgumentParser) throws -> AppsOptions {
        var udid: String?
        var includeSystem = false
        var json = false
        while let arg = parser.consume() {
            switch arg {
            case "--udid": udid = try parser.value(for: arg)
            case "--system": includeSystem = true
            case "--json": json = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.unknownOption(arg)
                }
                throw CLIParseError.unexpectedArgument(arg)
            }
        }
        return AppsOptions(udid: udid, includeSystem: includeSystem, json: json)
    }

    private static func parseFlow(_ parser: inout ArgumentParser) throws -> FlowOptions {
        let file = try parser.requiredPositional("file")
        var options = FlowOptions(file: file)
        while let arg = parser.consume() {
            switch arg {
            case "--udid":
                throw CLIParseError.unknownOption(arg)
            case "--verbose": options.verbose = true
            default:
                guard arg.hasPrefix("--") else { throw CLIParseError.unexpectedArgument(arg) }
                let key = String(arg.dropFirst(2))
                if key == "udid" || key.hasPrefix("udid=") {
                    throw CLIParseError.unknownOption("--udid")
                }
                guard !key.isEmpty else { throw CLIParseError.unknownOption(arg) }
                guard isFlowExternalVarName(key) else {
                    throw CLIParseError.invalidValue("Invalid flow external variable name: \(key)")
                }
                options.externalVars[key] = try parser.flowVariableValue(for: arg)
            }
        }
        return options
    }

    private static func parseNSLog(_ parser: inout ArgumentParser) throws -> NSLogOptions {
        var options = NSLogOptions(command: .stream)
        while let arg = parser.consume() {
            switch arg {
            case "start":
                guard options.command == .stream, options.name == nil, options.pattern == nil, options.flags.isEmpty else {
                    throw CLIParseError.unexpectedArgument(arg)
                }
                options.command = .start
                while let startArg = parser.consume() {
                    switch startArg {
                    case "--name": options.name = try parser.value(for: startArg)
                    default: throw CLIParseError.unknownOption(startArg)
                    }
                }
            case "read":
                guard options.command == .stream, options.name == nil, options.pattern == nil, options.flags.isEmpty else {
                    throw CLIParseError.unexpectedArgument(arg)
                }
                options.command = .read
                while let readArg = parser.consume() {
                    switch readArg {
                    case "--pattern": options.pattern = try parser.valueAllowingLeadingDash(for: readArg)
                    case "--flags": options.flags = try parser.value(for: readArg)
                    case "--timeout": options.timeout = try parseNonNegativeDoubleStrict(parser.valueAllowingLeadingDash(for: readArg), label: readArg)
                    case "--clearAfterRead": options.clearAfterRead = true
                    case "--last": options.last = try parsePositiveIntStrict(parser.value(for: readArg), label: readArg)
                    default: throw CLIParseError.unknownOption(readArg)
                    }
                }
            case "stop":
                guard options.command == .stream, options.name == nil, options.pattern == nil, options.flags.isEmpty else {
                    throw CLIParseError.unexpectedArgument(arg)
                }
                options.command = .stop
            case "--name": options.name = try parser.value(for: arg)
            case "--grep", "--flags":
                throw CLIParseError.invalidValue("\(arg) moved to `ios-use nslog read`. Use `ios-use nslog read --pattern <regex> --flags <flags>`.")
            case "--capture-mode": options.captureMode = try parser.value(for: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return options
    }

    private static func parseProxy(_ parser: inout ArgumentParser) throws -> ProxyCommand {
        let subcommand = try parser.requiredPositional("subcommand")
        switch subcommand {
        case "configca":
            var markTrusted = false
            while let arg = parser.consume() {
                switch arg {
                case "--mark-trusted": markTrusted = true
                default: throw CLIParseError.unknownOption(arg)
                }
            }
            return .configca(markTrusted: markTrusted)
        case "start":
            var interfaceName: String?
            var serverOnly = false
            while let arg = parser.consume() {
                switch arg {
                case "-i", "--interface": interfaceName = try parser.value(for: arg)
                case "--server": serverOnly = true
                default: throw CLIParseError.unknownOption(arg)
                }
            }
            return .start(interfaceName: interfaceName, serverOnly: serverOnly)
        case "read":
            var filter: String?
            var raw = false
            var last: Int?
            while let arg = parser.consume() {
                switch arg {
                case "--filter": filter = try parser.valueAllowingLeadingDash(for: arg)
                case "--raw": raw = true
                case "--last": last = try parsePositiveIntStrict(parser.value(for: arg), label: arg)
                default: throw CLIParseError.unknownOption(arg)
                }
            }
            return .read(filter: filter, raw: raw, last: last)
        case "stop":
            var serverOnly = false
            while let arg = parser.consume() {
                switch arg {
                case "--server": serverOnly = true
                default: throw CLIParseError.unknownOption(arg)
                }
            }
            return .stop(serverOnly: serverOnly)
        case "doctor":
            try parser.requireEnd()
            return .doctor
        default:
            throw CLIParseError.unknownCommand("proxy \(subcommand)")
        }
    }

    private static func parseTap(_ parser: inout ArgumentParser) throws -> DriverAction {
        let target = try parser.requiredPositional("target")
        var offset: String?
        var offsetRatio: String?
        var traits: String?
        var cindex: Int32?
        var domAfterMs: Int?
        while let arg = parser.consume() {
            switch arg {
            case "--offset": offset = try parser.valueAllowingLeadingDash(for: arg)
            case "--offset-ratio": offsetRatio = try parser.valueAllowingLeadingDash(for: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--dom": domAfterMs = try parseNonNegativeIntStrict(parser.optionalValueAllowingLeadingDash(defaultValue: "200"), label: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return .tap(target: target, offset: offset, offsetRatio: offsetRatio, traits: traits, cindex: cindex, domAfterMs: domAfterMs)
    }

    private static func parseLongPress(_ parser: inout ArgumentParser) throws -> DriverAction {
        let target = try parser.requiredPositional("target")
        var duration: Int?
        var traits: String?
        var cindex: Int32?
        var domAfterMs: Int?
        while let arg = parser.consume() {
            switch arg {
            case "--duration": duration = try parseNonNegativeIntStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--dom": domAfterMs = try parseNonNegativeIntStrict(parser.optionalValueAllowingLeadingDash(defaultValue: "200"), label: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return .longPress(target: target, duration: duration, traits: traits, cindex: cindex, domAfterMs: domAfterMs)
    }

    private static func parseInput(_ parser: inout ArgumentParser) throws -> DriverAction {
        var tap: String?
        var content: String?
        var traits: String?
        var cindex: Int32?
        var domAfterMs: Int?
        while let arg = parser.consume() {
            switch arg {
            case "--tap": tap = try parser.value(for: arg)
            case "--label": throw CLIParseError.invalidValue("input --label was replaced by --tap <target>")
            case "--content": content = try parser.valueAllowingLeadingDash(for: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--dom": domAfterMs = try parseNonNegativeIntStrict(parser.optionalValueAllowingLeadingDash(defaultValue: "200"), label: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        _ = try DriverCommandExecutor.resolveInputTapTarget(tap, traits: traits, cindex: cindex)
        return .input(tap: tap, content: try require(content, option: "--content"), traits: traits, cindex: cindex, domAfterMs: domAfterMs)
    }

    private static func parseSwipe(_ parser: inout ArgumentParser) throws -> DriverAction {
        var to: String?
        var from: String?
        var dir: String?
        var distance: Double?
        var traits: String?
        var cindex: Int32?
        var domAfterMs: Int?
        while let arg = parser.consume() {
            switch arg {
            case "--to": to = try parser.value(for: arg)
            case "--from": from = try parser.value(for: arg)
            case "--dir":
                let value = try parser.value(for: arg)
                guard value == "forth" || value == "back" else { throw CLIParseError.invalidValue("Invalid swipe dir: \"\(value)\", expected \"forth\" or \"back\"") }
                dir = value
            case "--distance": distance = try parseNonNegativeDoubleStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--dom": domAfterMs = try parseNonNegativeIntStrict(parser.optionalValueAllowingLeadingDash(defaultValue: "200"), label: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return .swipe(to: to, from: from, dir: dir, distance: distance, traits: traits, cindex: cindex, domAfterMs: domAfterMs)
    }

    private static func parseDom(_ parser: inout ArgumentParser) throws -> DriverAction {
        var raw = false
        var fresh = false
        while let arg = parser.consume() {
            switch arg {
            case "--raw": raw = true
            case "--fresh": fresh = true
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return .dom(raw: raw, fresh: fresh)
    }

    private static func parseFind(_ parser: inout ArgumentParser) throws -> DriverAction {
        let label = try parser.requiredPositional("label")
        var traits: String?
        var cindex: Int32?
        while let arg = parser.consume() {
            switch arg {
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return .find(label: label, traits: traits, cindex: cindex)
    }

    private static func parseScreenshot(_ parser: inout ArgumentParser) throws -> DriverAction {
        var name: String?
        while let arg = parser.consume() {
            switch arg {
            case "--name": name = try parser.value(for: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return .screenshot(name: name)
    }

    private static func parseWaitFor(_ parser: inout ArgumentParser) throws -> DriverAction {
        var label: String?
        var timeout: Double?
        var traits: String?
        var cindex: Int32?
        while let arg = parser.consume() {
            switch arg {
            case "--label": label = try parser.value(for: arg)
            case "--timeout": timeout = try parseNonNegativeDoubleStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return .waitFor(label: try require(label, option: "--label"), timeout: timeout, traits: traits, cindex: cindex)
    }

    private enum BundleActionKind {
        case activateApp
        case terminateApp
    }

    private static func parseBundleAction(_ parser: inout ArgumentParser, kind: BundleActionKind) throws -> DriverAction {
        let bundleId = try parser.requiredPositional("bundleId")
        try parser.requireEnd()
        switch kind {
        case .activateApp: return .activateApp(bundleId: bundleId)
        case .terminateApp: return .terminateApp(bundleId: bundleId)
        }
    }

    private static func parseHome(_ parser: inout ArgumentParser) throws -> DriverAction {
        try parser.requireEnd()
        return .home
    }

    private static func parseOpen(_ parser: inout ArgumentParser) throws -> OpenURLOptions {
        let url = try parser.requiredPositional("url")
        var session = SessionOptions()
        while let arg = parser.consume() {
            try parseSession(arg, parser: &parser, session: &session)
        }
        return OpenURLOptions(url: url, session: session)
    }

    private static func parseDismissAlert(_ parser: inout ArgumentParser) throws -> DriverAction {
        var index: Int?
        while let arg = parser.consume() {
            switch arg {
            case "--index": index = try parseNonNegativeIntStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return .dismissAlert(index: index)
    }

    private static func parseOSLog(_ parser: inout ArgumentParser) throws -> OSLogOptions {
        var pattern: String?
        var flags: String?
        var timeout: Double?
        var process: String?
        var pid: Int?
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--pattern": pattern = try parser.valueAllowingLeadingDash(for: arg)
            case "--flags": flags = try parser.value(for: arg)
            case "--timeout": timeout = try parseNonNegativeDoubleStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--process":
                guard process == nil else { throw CLIParseError.invalidValue("--process can only be provided once") }
                guard pid == nil else { throw CLIParseError.invalidValue("--process and --pid are mutually exclusive") }
                process = try parser.value(for: arg)
            case "--pid":
                guard pid == nil else { throw CLIParseError.invalidValue("--pid can only be provided once") }
                guard process == nil else { throw CLIParseError.invalidValue("--process and --pid are mutually exclusive") }
                pid = try parseNonNegativeIntStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return OSLogOptions(pattern: pattern, flags: flags, timeout: timeout, source: .init(process: process, pid: pid), session: session)
    }

    private static func parseSession(_ arg: String, parser: inout ArgumentParser, session: inout SessionOptions) throws {
        switch arg {
        case "--udid": session.udid = try parser.value(for: arg)
        case "--verbose": session.verbose = true
        default: throw CLIParseError.unknownOption(arg)
        }
    }

    private static func require(_ value: String?, option: String) throws -> String {
        guard let value else { throw CLIParseError.missingRequiredOption(option) }
        return value
    }

    private static func parseIntStrict(_ value: String, label: String) throws -> Int {
        guard value.range(of: #"^[+-]?\d+$"#, options: .regularExpression) != nil, let intValue = Int(value) else {
            throw CLIParseError.invalidValue("Invalid integer: \"\(value)\"")
        }
        return intValue
    }

    private static func parseInt32Strict(_ value: String, label: String) throws -> Int32 {
        let parsed = try parseIntStrict(value, label: label)
        guard parsed >= Int(Int32.min), parsed <= Int(Int32.max) else {
            throw CLIParseError.invalidValue("\(label) is out of Int32 range")
        }
        return Int32(parsed)
    }

    private static func parseDoubleStrict(_ value: String, label: String) throws -> Double {
        guard value.range(of: #"^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$"#, options: .regularExpression) != nil, let doubleValue = Double(value), doubleValue.isFinite else {
            throw CLIParseError.invalidValue("Invalid number: \"\(value)\"")
        }
        return doubleValue
    }

    private static func parseNonNegativeIntStrict(_ value: String, label: String) throws -> Int {
        let parsed = try parseIntStrict(value, label: label)
        guard parsed >= 0 else {
            throw CLIParseError.invalidValue("\(label) must be non-negative")
        }
        return parsed
    }

    private static func parsePositiveIntStrict(_ value: String, label: String) throws -> Int {
        let parsed = try parseIntStrict(value, label: label)
        guard parsed > 0 else {
            throw CLIParseError.invalidValue("\(label) must be greater than 0")
        }
        return parsed
    }

    private static func parseNonNegativeDoubleStrict(_ value: String, label: String) throws -> Double {
        let parsed = try parseDoubleStrict(value, label: label)
        guard parsed >= 0 else {
            throw CLIParseError.invalidValue("\(label) must be non-negative")
        }
        return parsed
    }

    private static func isFlowExternalVarName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    }
}

public enum CLIParseError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingCommand
    case unknownCommand(String)
    case unknownOption(String)
    case missingRequiredOption(String)
    case missingRequiredArgument(String)
    case missingOptionValue(String)
    case unexpectedArgument(String)
    case invalidValue(String)

    public var description: String {
        switch self {
        case .missingCommand:
            return "missing command"
        case .unknownCommand(let command):
            return "unknown command '\(command)'"
        case .unknownOption(let option):
            return "unknown option '\(option)'"
        case .missingRequiredOption(let option):
            return "required option '\(option)' not specified"
        case .missingRequiredArgument(let argument):
            return "missing required argument '\(argument)'"
        case .missingOptionValue(let option):
            return "option '\(option)' argument missing"
        case .unexpectedArgument(let argument):
            return "unexpected argument '\(argument)'"
        case .invalidValue(let message):
            return message
        }
    }
}

private struct ArgumentParser {
    private static let inlineValuePrefix = "\u{0}inline:"
    private let arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = Self.expandInlineLongOptions(arguments)
    }

    mutating func consume() -> String? {
        guard index < arguments.count else { return nil }
        let value = arguments[index]
        index += 1
        return value
    }

    mutating func requiredPositional(_ name: String) throws -> String {
        guard let value = consume(), !value.hasPrefix("-") else {
            throw CLIParseError.missingRequiredArgument(name)
        }
        return value
    }

    mutating func value(for option: String) throws -> String {
        guard let value = consume(), !value.hasPrefix("-") else {
            throw CLIParseError.missingOptionValue(option)
        }
        return Self.stripInlinePrefix(value)
    }

    mutating func valueAllowingLeadingDash(for option: String) throws -> String {
        guard let value = consume() else {
            throw CLIParseError.missingOptionValue(option)
        }
        return Self.stripInlinePrefix(value)
    }

    mutating func optionalValueAllowingLeadingDash(defaultValue: String) -> String {
        guard index < arguments.count else { return defaultValue }
        let value = arguments[index]
        if value.hasPrefix("--"), !value.hasPrefix(Self.inlineValuePrefix) {
            return defaultValue
        }
        index += 1
        return Self.stripInlinePrefix(value)
    }

    mutating func flowVariableValue(for option: String) throws -> String {
        guard let value = consume(), value.hasPrefix(Self.inlineValuePrefix) || !value.hasPrefix("--") else {
            throw CLIParseError.missingOptionValue(option)
        }
        return Self.stripInlinePrefix(value)
    }

    mutating func requireEnd() throws {
        if let arg = consume() {
            if arg.hasPrefix("-") {
                throw CLIParseError.unknownOption(arg)
            }
            throw CLIParseError.unexpectedArgument(arg)
        }
    }

    private static func expandInlineLongOptions(_ arguments: [String]) -> [String] {
        var expanded: [String] = []
        for argument in arguments {
            guard argument.hasPrefix("--"),
                  argument != "--",
                  let equals = argument.firstIndex(of: "=") else {
                expanded.append(argument)
                continue
            }
            let option = String(argument[..<equals])
            let value = String(argument[argument.index(after: equals)...])
            guard option.count > 2 else {
                expanded.append(argument)
                continue
            }
            expanded.append(option)
            expanded.append(inlineValuePrefix + value)
        }
        return expanded
    }

    private static func stripInlinePrefix(_ value: String) -> String {
        value.hasPrefix(inlineValuePrefix) ? String(value.dropFirst(inlineValuePrefix.count)) : value
    }
}
