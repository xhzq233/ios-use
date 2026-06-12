import Foundation

public enum ParsedCommand: Equatable, Sendable {
    case devices(DeviceOptions)
    case config(ConfigOptions)
    case start(StartOptions)
    case stop
    case install(AppInstallOptions)
    case uninstall(AppUninstallOptions)
    case apps(AppsOptions)
    case ddiMount(DDIMountOptions)
    case open(OpenURLOptions)
    case appLifecycle(AppLifecycleOptions)
    case logRead(AppLogReadOptions)
    case oslog(OSLogOptions)
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
        case .install: return "install"
        case .uninstall: return "uninstall"
        case .apps: return "apps"
        case .ddiMount: return "ddi-mount"
        case .open: return "open"
        case .appLifecycle(let options): return options.action.commandName
        case .logRead: return "log-read"
        case .oslog: return "oslog"
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
    public var udid: String?
    public var verbose = false

    public init(udid: String? = nil, verbose: Bool = false) {
        self.udid = udid
        self.verbose = verbose
    }
}

public struct AppInstallOptions: Equatable, Sendable {
    public var ipaPath: String
    public var udid: String?
    public var verbose: Bool

    public init(ipaPath: String, udid: String? = nil, verbose: Bool = false) {
        self.ipaPath = ipaPath
        self.udid = udid
        self.verbose = verbose
    }
}

public struct AppUninstallOptions: Equatable, Sendable {
    public var bundleID: String
    public var udid: String?
    public var verbose: Bool

    public init(bundleID: String, udid: String? = nil, verbose: Bool = false) {
        self.bundleID = bundleID
        self.udid = udid
        self.verbose = verbose
    }
}

public struct AppsOptions: Equatable, Sendable {
    public var udid: String?
    public var includeSystem: Bool
    public var json: Bool

    public init(udid: String? = nil, includeSystem: Bool = false, json: Bool = false) {
        self.udid = udid
        self.includeSystem = includeSystem
        self.json = json
    }
}

public struct DDIMountOptions: Equatable, Sendable {
    public var path: String?
    public var udid: String?

    public init(path: String? = nil, udid: String? = nil) {
        self.path = path
        self.udid = udid
    }
}

public struct OpenURLOptions: Equatable, Sendable {
    public var url: String
    public var session: SessionOptions

    public init(url: String, session: SessionOptions = SessionOptions()) {
        self.url = url
        self.session = session
    }
}

public struct AppLifecycleOptions: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case activate
        case terminate

        public var commandName: String {
            switch self {
            case .activate: return "activateApp"
            case .terminate: return "terminateApp"
            }
        }
    }

    public var action: Action
    public var bundleID: String
    public var session: SessionOptions
    public var terminateExisting: Bool
    public var log: Bool

    public init(action: Action, bundleID: String, session: SessionOptions = SessionOptions(), terminateExisting: Bool = false, log: Bool = false) {
        self.action = action
        self.bundleID = bundleID
        self.session = session
        self.terminateExisting = terminateExisting
        self.log = log
    }
}

public struct AppLogReadOptions: Equatable, Sendable {
    public var pattern: String?
    public var flags: String
    public var timeout: Double?
    public var clearAfterRead: Bool
    public var last: Int?

    public init(pattern: String? = nil, flags: String = "", timeout: Double? = nil, clearAfterRead: Bool = false, last: Int? = nil) {
        self.pattern = pattern
        self.flags = flags
        self.timeout = timeout
        self.clearAfterRead = clearAfterRead
        self.last = last
    }
}

public struct OSLogOptions: Equatable, Sendable {
    public struct SourceFilter: Equatable, Sendable {
        public var process: String?
        public var pid: Int?

        public init(process: String? = nil, pid: Int? = nil) {
            self.process = process
            self.pid = pid
        }
    }

    public var pattern: String?
    public var flags: String?
    public var timeout: Double?
    public var source: SourceFilter
    public var session: SessionOptions

    public init(pattern: String? = nil, flags: String? = nil, timeout: Double? = nil, source: SourceFilter = SourceFilter(), session: SessionOptions = SessionOptions()) {
        self.pattern = pattern
        self.flags = flags
        self.timeout = timeout
        self.source = source
        self.session = session
    }
}

public enum PostDomMode: Equatable, Sendable {
    case afterQuiescence
    case afterMilliseconds(Int)
}

public enum DriverAction: Equatable, Sendable {
    case tap(target: String, offset: String?, offsetRatio: String?, traits: String?, cindex: Int32?, postDom: PostDomMode?)
    case longPress(target: String, duration: Int?, traits: String?, cindex: Int32?, postDom: PostDomMode?)
    case input(tap: String?, content: String, delete: Int, enter: Bool, traits: String?, cindex: Int32?, postDom: PostDomMode?)
    case swipe(to: String?, from: String?, dir: String?, distance: Double?, traits: String?, cindex: Int32?, postDom: PostDomMode?)
    case dom(raw: Bool, fresh: Bool, waitQuiescence: Bool)
    case screenshot(name: String?)
    case waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?)
    case activateApp(bundleId: String)
    case terminateApp(bundleId: String)
    case home
    case dismissAlert(index: Int?)

    public var name: String {
        switch self {
        case .tap: return "tap"
        case .longPress: return "longpress"
        case .input: return "input"
        case .swipe: return "swipe"
        case .dom: return "dom"
        case .screenshot: return "screenshot"
        case .waitFor: return "waitFor"
        case .activateApp: return "activateApp"
        case .terminateApp: return "terminateApp"
        case .home: return "home"
        case .dismissAlert: return "dismissAlert"
        }
    }
}

public struct FlowOptions: Equatable, Sendable {
    public var file: String
    public var verbose = false
    public var externalVars: [String: String] = [:]

    public init(file: String, verbose: Bool = false, externalVars: [String: String] = [:]) {
        self.file = file
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
    case configca(markTrusted: Bool)
    case start(interfaceName: String?, serverOnly: Bool)
    case read(filter: String?, raw: Bool, last: Int?)
    case stop(serverOnly: Bool)
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
