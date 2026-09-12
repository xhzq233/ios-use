import Foundation
import IOSUseProtocol

final class MCPDriverSessionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: LockedDriverClientSession] = [:]
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func session(paths: IOSUsePaths) -> LockedDriverClientSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[paths.driverLock] { return existing }
        let created = LockedDriverClientSession(paths: paths)
        sessions[paths.driverLock] = created
        return created
    }

    func close() {
        lock.lock()
        let current = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        current.forEach { $0.close() }
    }

    deinit { close() }
}

/// Native services shared with the CLI, without argv, output parsing or a socket.
final class MCPRuntimeHost: @unchecked Sendable {
    struct Result {
        var data: MachineValue = .null
        var image: Data? = nil
        var error: MachineValue? = nil
    }

    private let paths: IOSUsePaths
    private let pool = MCPDriverSessionPool()

    init(paths: IOSUsePaths) { self.paths = paths }
    func cancel() { pool.cancel() }

    // Issued operations retain this host until they drain. Reset does not wait
    // for them; queued operations check cancellation before touching the Device.
    func call(_ name: String, deviceID: String?, options: [String: MachineValue]) -> Result {
        let state = CLIInvocationState()
        return CLIInvocationContext.$current.withValue(state) {
            do {
                try pool.checkCancellation()
                return try perform(name, deviceID: deviceID, options: options)
            } catch {
                let classified = MachineOutput.classify(error)
                let snapshot = state.snapshot()
                var data = machineDriverErrorData(error)
                if let readiness = error as? AppLifecycleService.ReadinessError,
                   case .string(let bundleID) = options["bundleId"] {
                    data = AppLifecycleService.machineData(options: AppLifecycleOptions(action: .activate, bundleID: bundleID, dom: true), result: readiness.hostResult)
                }
                return Result(error: .object([
                    "command": .string(name),
                    "error": .object([
                        "message": .string(classified.message), "code": .string(classified.code),
                        "category": .string(classified.category), "retryable": .boolean(classified.retryable),
                        "mutationMayHaveApplied": .boolean(classified.mutationMayHaveApplied),
                    ]),
                    "data": data,
                    "interaction": snapshot.interactionState ?? .null,
                    "warnings": .array(snapshot.warnings.map(MachineValue.string)),
                ]))
            }
        }
    }

    private func perform(_ name: String, deviceID: String?, options: [String: MachineValue]) throws -> Result {
        let args = MCPNativeArguments(options)
        if name == "status" { return Result(data: StatusService.machineSnapshot(paths: paths).data) }
        if name == "readImage" {
            guard let url = URL(string: try args.string("url")), url.isFileURL,
                  url.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: paths.root).standardizedFileURL.path + "/") else {
                throw CLIParseError.invalidValue("Image path is outside IOS_USE_HOME")
            }
            return Result(image: try Data(contentsOf: url))
        }
        guard let deviceID else { throw CLIParseError.invalidValue("A Device ID is required") }
        let id = try DeviceContextStore.normalizeExplicitDeviceID(deviceID, paths: paths)
        if name == "apps" {
            guard id != "mac" else { throw CLIParseError.invalidValue("listApps supports real iOS and Simulator") }
            let result = try AppManagementService.listResult(options: AppsOptions(udid: id, includeSystem: args.bool("includeSystem")), paths: paths)
            return Result(data: AppManagementService.machineAppsData(result))
        }
        if name == "start" {
            guard id != "mac" else { throw CLIParseError.invalidValue("Use native ios-use start --mac for setup") }
            let targetPaths = try DeviceContextStore.sessions(paths: paths).first(where: { $0.deviceID == id })?.paths
                ?? paths.deviceContext(id)
            _ = try SessionService.start(udid: id, paths: targetPaths, verbose: false)
            return Result(data: StatusService.machineSnapshot(paths: paths).data)
        }
        let context = try DeviceContextStore.activeContext(explicitDeviceID: id, paths: paths)
        if name == "stop" {
            _ = try SessionService.stop(paths: context.paths)
            return Result(data: StatusService.machineSnapshot(paths: paths).data)
        }
        return try DeviceCommandLock.withExclusiveLock(paths: context.paths) {
            try pool.checkCancellation()
            let session = pool.session(paths: context.paths)
            if name == "activateApp" || name == "terminateApp" {
                guard id != "mac" else { throw CLIParseError.invalidValue("Mac App lifecycle uses native start/stop") }
                let options = AppLifecycleOptions(action: name == "activateApp" ? .activate : .terminate,
                    bundleID: try args.string("bundleId"), terminateExisting: args.bool("terminateExisting"), dom: true)
                let result = try AppLifecycleService.runWithReadiness(options: options, paths: context.paths, driverSession: session)
                return Result(data: AppLifecycleService.machineData(options: options, result: result))
            }
            return try session.run { client in
                switch name {
                case "observe":
                    var data: [String: MachineValue] = [:]
                    let ax = args.bool("ax")
                    let wait = args.bool("waitQuiescence", default: true)
                    if ax { data["ax"] = machineDom(try client.dom(raw: false, fresh: true, waitQuiescence: wait), presentation: false) }
                    var image: Data?
                    if args.bool("screenshot") {
                        let capture = try ScreenshotCaptureCoordinator.capture(paths: context.paths) {
                            try client.screenshotCapture(waitQuiescence: wait && !ax)
                        }
                        image = capture.jpeg
                        data["screenshot"] = .object([
                            "logicalSize": capture.logicalSize.map { .array([.double($0.x), .double($0.y)]) } ?? .null,
                            "pixelSize": capture.pixelSize.map { .array([.double($0.x), .double($0.y)]) } ?? .null,
                            "scale": capture.scale.map(MachineValue.double) ?? .null,
                        ])
                    }
                    return Result(data: .object(data), image: image)
                case "click":
                    guard let count = Int(exactly: try args.number("clickCount", default: 1)), (1...10).contains(count) else {
                        throw CLIParseError.invalidValue("clickCount must be an integer from 1 to 10")
                    }
                    _ = try client.click(target: args.target("target"), count: count)
                case "replace", "select", "key", "type":
                    _ = try client.textInput(ForyTextInputArgs(operation: name, target: args.target("target"),
                        text: args.string("text", default: ""), prefix: args.string("prefix", default: ""),
                        suffix: args.string("suffix", default: ""), selectionType: args.string("selectionType", default: "text")))
                case "longpress":
                    guard let milliseconds = Int(exactly: (try args.number("duration") * 1000).rounded()), milliseconds > 0 else {
                        throw CLIParseError.invalidValue("longPress duration must be positive representable milliseconds")
                    }
                    let payload = try client.longPress(target: args.target("target"),
                        durationMs: milliseconds, traits: nil, cindex: nil)
                    return Result(data: machineAction(payload))
                case "swipe":
                    let payload = try client.swipe(to: args.target("to"), from: args.target("from"), distance: nil, dir: nil, traits: nil, cindex: nil)
                    return Result(data: machineSwipe(payload))
                case "waitFor":
                    let match = try args.string("match", default: "contains")
                    guard let mode: IOSUseWaitForMatchMode = ["contains": .standard, "exact": .exact, "regex": .regex][match] else {
                        throw CLIParseError.invalidValue("Unknown waitFor match mode: \(match)")
                    }
                    _ = try client.waitFor(label: args.string("text"), timeout: args.number("timeout", default: 10),
                        traits: nil, cindex: nil, gone: args.bool("gone"), matchMode: mode)
                default: throw CLIParseError.invalidValue("Unknown Device operation: \(name)")
                }
                return Result()
            }
        }
    }
}

private struct MCPNativeArguments {
    let values: [String: MachineValue]
    init(_ values: [String: MachineValue]) { self.values = values }

    func string(_ key: String, default fallback: String? = nil) throws -> String {
        if case .string(let value) = values[key] { return value }
        if let fallback, values[key] == nil || values[key] == .null { return fallback }
        throw CLIParseError.invalidValue("\(key) must be a string")
    }

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        if case .boolean(let value) = values[key] { return value }
        return fallback
    }

    func number(_ key: String, default fallback: Double? = nil) throws -> Double {
        if case .double(let value) = values[key], value.isFinite { return value }
        if case .integer(let value) = values[key] { return Double(value) }
        if let fallback, values[key] == nil || values[key] == .null { return fallback }
        throw CLIParseError.invalidValue("\(key) must be a finite number")
    }

    func target(_ key: String) throws -> ForyTarget {
        guard let value = values[key], value != .null else { return ForyTarget() }
        guard case .object(let fields) = value else { throw CLIParseError.invalidValue("Expected a label or [x,y] target") }
        if case .string(let label) = fields["label"], !label.isEmpty { return ForyTarget(label: label) }
        if case .array(let point) = fields["point"], point.count == 2 {
            let coords = MCPNativeArguments(["x": point[0], "y": point[1]])
            return try ForyTarget(point: ForyPoint(x: coords.number("x"), y: coords.number("y")))
        }
        throw CLIParseError.invalidValue("Expected a label or [x,y] target")
    }
}
