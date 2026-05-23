import Foundation

public enum ParsedCommand: Equatable, Sendable {
    case devices(DeviceOptions)
    case config(ConfigOptions)
    case start(StartOptions)
    case stop
    case driver(DriverAction)
    case flow(FlowOptions)
    case nslog(NSLogOptions)
    case proxy(ProxyCommand)

    public var commandName: String {
        switch self {
        case .devices: return "devices"
        case .config: return "config"
        case .start: return "start"
        case .stop: return "stop"
        case .driver(let action): return action.name
        case .flow: return "flow"
        case .nslog: return "nslog"
        case .proxy(let command): return "proxy \(command.subcommand)"
        }
    }
}

public struct DeviceOptions: Equatable, Sendable {
    public var simulator = false
    public var verbose = false

    public init(simulator: Bool = false, verbose: Bool = false) {
        self.simulator = simulator
        self.verbose = verbose
    }
}

public struct ConfigOptions: Equatable, Sendable {
    public var udid: String?
    public var list = false
    public var simulator = false
    public var appleId: String?
    public var password: String?
    public var verbose = false

    public init(udid: String? = nil, list: Bool = false, simulator: Bool = false, appleId: String? = nil, password: String? = nil, verbose: Bool = false) {
        self.udid = udid
        self.list = list
        self.simulator = simulator
        self.appleId = appleId
        self.password = password
        self.verbose = verbose
    }
}

public struct SessionOptions: Equatable, Sendable {
    public var udid: String?
    public var verbose = false

    public init(udid: String? = nil, verbose: Bool = false) {
        self.udid = udid
        self.verbose = verbose
    }
}

public struct StartOptions: Equatable, Sendable {
    public var udid: String
    public var verbose = false

    public init(udid: String, verbose: Bool = false) {
        self.udid = udid
        self.verbose = verbose
    }
}

public enum DriverAction: Equatable, Sendable {
    case tap(target: String, offset: String?, offsetRatio: String?, traits: String?, cindex: Int32?, session: SessionOptions)
    case longPress(target: String, duration: Int?, traits: String?, cindex: Int32?, session: SessionOptions)
    case input(label: String, content: String, traits: String?, cindex: Int32?, session: SessionOptions)
    case swipe(to: String?, from: String?, dir: String?, distance: Double?, traits: String?, cindex: Int32?, session: SessionOptions)
    case dom(raw: Bool, fresh: Bool, session: SessionOptions)
    case find(label: String, traits: String?, cindex: Int32?, session: SessionOptions)
    case screenshot(name: String?, session: SessionOptions)
    case waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?, session: SessionOptions)
    case activateApp(bundleId: String, session: SessionOptions)
    case terminateApp(bundleId: String, session: SessionOptions)
    case home(session: SessionOptions)
    case openURL(url: String, session: SessionOptions)
    case dismissAlert(index: Int?, session: SessionOptions)
    case oslog(pattern: String?, flags: String?, timeout: Double?, name: String?, clear: Bool, bundleId: String?, session: SessionOptions)

    public var name: String {
        switch self {
        case .tap: return "tap"
        case .longPress: return "longpress"
        case .input: return "input"
        case .swipe: return "swipe"
        case .dom: return "dom"
        case .find: return "find"
        case .screenshot: return "screenshot"
        case .waitFor: return "waitFor"
        case .activateApp: return "activateApp"
        case .terminateApp: return "terminateApp"
        case .home: return "home"
        case .openURL: return "openURL"
        case .dismissAlert: return "dismissAlert"
        case .oslog: return "oslog"
        }
    }

    public var session: SessionOptions {
        switch self {
        case .tap(_, _, _, _, _, let session),
             .longPress(_, _, _, _, let session),
             .input(_, _, _, _, let session),
             .swipe(_, _, _, _, _, _, let session),
             .dom(_, _, let session),
             .find(_, _, _, let session),
             .screenshot(_, let session),
             .waitFor(_, _, _, _, let session),
             .activateApp(_, let session),
             .terminateApp(_, let session),
             .home(let session),
             .openURL(_, let session),
             .dismissAlert(_, let session),
             .oslog(_, _, _, _, _, _, let session):
            return session
        }
    }
}

public struct FlowOptions: Equatable, Sendable {
    public var file: String
    public var udid: String?
    public var verbose = false
    public var externalVars: [String: String] = [:]

    public init(file: String, udid: String? = nil, verbose: Bool = false, externalVars: [String: String] = [:]) {
        self.file = file
        self.udid = udid
        self.verbose = verbose
        self.externalVars = externalVars
    }
}

public struct NSLogOptions: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case stream
        case start
        case read
        case stop
    }

    public var command: Command
    public var name: String?
    public var pattern: String?
    public var flags = ""
    public var timeout: Double?
    public var clearAfterRead = false
    public var last: Int?
    public var captureMode: String?

    public init(command: Command = .stream, name: String? = nil, pattern: String? = nil, flags: String = "", timeout: Double? = nil, clearAfterRead: Bool = false, last: Int? = nil, captureMode: String? = nil) {
        self.command = command
        self.name = name
        self.pattern = pattern
        self.flags = flags
        self.timeout = timeout
        self.clearAfterRead = clearAfterRead
        self.last = last
        self.captureMode = captureMode
    }
}

public enum ProxyCommand: Equatable, Sendable {
    case configca(udid: String?)
    case start(udid: String?, interfaceName: String?)
    case read(filter: String?, raw: Bool, last: Int?)
    case stop(udid: String?)
    case doctor

    public var subcommand: String {
        switch self {
        case .configca: return "configca"
        case .start: return "start"
        case .read: return "read"
        case .stop: return "stop"
        case .doctor: return "doctor"
        }
    }
}

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
            return .driver(try parseOpen(&parser))
        case "dismissAlert":
            return .driver(try parseDismissAlert(&parser))
        case "oslog":
            return .driver(try parseOSLog(&parser))
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

    private static func parseFlow(_ parser: inout ArgumentParser) throws -> FlowOptions {
        let file = try parser.requiredPositional("file")
        var options = FlowOptions(file: file)
        while let arg = parser.consume() {
            switch arg {
            case "--udid": options.udid = try parser.value(for: arg)
            case "--verbose": options.verbose = true
            default:
                guard arg.hasPrefix("--") else { throw CLIParseError.unexpectedArgument(arg) }
                let key = String(arg.dropFirst(2))
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
            var udid: String?
            while let arg = parser.consume() {
                switch arg {
                case "--udid": udid = try parser.value(for: arg)
                default: throw CLIParseError.unknownOption(arg)
                }
            }
            return .configca(udid: udid)
        case "start":
            var udid: String?
            var interfaceName: String?
            while let arg = parser.consume() {
                switch arg {
                case "--udid": udid = try parser.value(for: arg)
                case "-i", "--interface": interfaceName = try parser.value(for: arg)
                default: throw CLIParseError.unknownOption(arg)
                }
            }
            return .start(udid: udid, interfaceName: interfaceName)
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
            var udid: String?
            while let arg = parser.consume() {
                switch arg {
                case "--udid": udid = try parser.value(for: arg)
                default: throw CLIParseError.unknownOption(arg)
                }
            }
            return .stop(udid: udid)
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
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--offset": offset = try parser.valueAllowingLeadingDash(for: arg)
            case "--offset-ratio": offsetRatio = try parser.valueAllowingLeadingDash(for: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .tap(target: target, offset: offset, offsetRatio: offsetRatio, traits: traits, cindex: cindex, session: session)
    }

    private static func parseLongPress(_ parser: inout ArgumentParser) throws -> DriverAction {
        let target = try parser.requiredPositional("target")
        var duration: Int?
        var traits: String?
        var cindex: Int32?
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--duration": duration = try parseNonNegativeIntStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .longPress(target: target, duration: duration, traits: traits, cindex: cindex, session: session)
    }

    private static func parseInput(_ parser: inout ArgumentParser) throws -> DriverAction {
        var label: String?
        var content: String?
        var traits: String?
        var cindex: Int32?
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--label": label = try parser.value(for: arg)
            case "--content": content = try parser.valueAllowingLeadingDash(for: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .input(label: try require(label, option: "--label"), content: try require(content, option: "--content"), traits: traits, cindex: cindex, session: session)
    }

    private static func parseSwipe(_ parser: inout ArgumentParser) throws -> DriverAction {
        var to: String?
        var from: String?
        var dir: String?
        var distance: Double?
        var traits: String?
        var cindex: Int32?
        var session = SessionOptions()
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
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .swipe(to: to, from: from, dir: dir, distance: distance, traits: traits, cindex: cindex, session: session)
    }

    private static func parseDom(_ parser: inout ArgumentParser) throws -> DriverAction {
        var raw = false
        var fresh = false
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--raw": raw = true
            case "--fresh": fresh = true
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .dom(raw: raw, fresh: fresh, session: session)
    }

    private static func parseFind(_ parser: inout ArgumentParser) throws -> DriverAction {
        let label = try parser.requiredPositional("label")
        var traits: String?
        var cindex: Int32?
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .find(label: label, traits: traits, cindex: cindex, session: session)
    }

    private static func parseScreenshot(_ parser: inout ArgumentParser) throws -> DriverAction {
        var name: String?
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--name": name = try parser.value(for: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .screenshot(name: name, session: session)
    }

    private static func parseWaitFor(_ parser: inout ArgumentParser) throws -> DriverAction {
        var label: String?
        var timeout: Double?
        var traits: String?
        var cindex: Int32?
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--label": label = try parser.value(for: arg)
            case "--timeout": timeout = try parseNonNegativeDoubleStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--traits": traits = try parser.value(for: arg)
            case "--cindex": cindex = try parseInt32Strict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .waitFor(label: try require(label, option: "--label"), timeout: timeout, traits: traits, cindex: cindex, session: session)
    }

    private enum BundleActionKind {
        case activateApp
        case terminateApp
    }

    private static func parseBundleAction(_ parser: inout ArgumentParser, kind: BundleActionKind) throws -> DriverAction {
        let bundleId = try parser.requiredPositional("bundleId")
        var session = SessionOptions()
        while let arg = parser.consume() {
            try parseSession(arg, parser: &parser, session: &session)
        }
        switch kind {
        case .activateApp: return .activateApp(bundleId: bundleId, session: session)
        case .terminateApp: return .terminateApp(bundleId: bundleId, session: session)
        }
    }

    private static func parseHome(_ parser: inout ArgumentParser) throws -> DriverAction {
        var session = SessionOptions()
        while let arg = parser.consume() {
            try parseSession(arg, parser: &parser, session: &session)
        }
        return .home(session: session)
    }

    private static func parseOpen(_ parser: inout ArgumentParser) throws -> DriverAction {
        let url = try parser.requiredPositional("url")
        var session = SessionOptions()
        while let arg = parser.consume() {
            try parseSession(arg, parser: &parser, session: &session)
        }
        return .openURL(url: url, session: session)
    }

    private static func parseDismissAlert(_ parser: inout ArgumentParser) throws -> DriverAction {
        var index: Int?
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--index": index = try parseNonNegativeIntStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .dismissAlert(index: index, session: session)
    }

    private static func parseOSLog(_ parser: inout ArgumentParser) throws -> DriverAction {
        var pattern: String?
        var flags: String?
        var timeout: Double?
        var name: String?
        var clear = false
        var bundleId: String?
        var session = SessionOptions()
        while let arg = parser.consume() {
            switch arg {
            case "--pattern": pattern = try parser.valueAllowingLeadingDash(for: arg)
            case "--flags": flags = try parser.value(for: arg)
            case "--timeout": timeout = try parseNonNegativeDoubleStrict(parser.valueAllowingLeadingDash(for: arg), label: arg)
            case "--name": name = try parser.value(for: arg)
            case "--clear": clear = true
            case "--bundle-id": bundleId = try parser.value(for: arg)
            default: try parseSession(arg, parser: &parser, session: &session)
            }
        }
        return .oslog(pattern: pattern, flags: flags, timeout: timeout, name: name, clear: clear, bundleId: bundleId, session: session)
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
