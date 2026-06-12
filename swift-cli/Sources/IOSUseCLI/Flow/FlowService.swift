import Foundation
import IOSUseProtocol
import Yams

protocol FlowDriver: DriverCommandClient {}

extension DriverClient: FlowDriver {}

public enum FlowService {
    public typealias OutputSink = @Sendable (String) -> Void

    public static func run(file: String, options: FlowOptions, paths: IOSUsePaths, outputSink: OutputSink? = nil) throws -> String {
        let resolvedFile = URL(fileURLWithPath: file).standardized.path
        guard FileManager.default.fileExists(atPath: resolvedFile) else {
            throw CLIParseError.invalidValue("Flow file not found: \(file)")
        }
        let context = FlowRunContext()
        let flow = try loadFlowFile(resolvedFile)
        context.flowCache[resolvedFile] = flow
        try compileFlow(file: resolvedFile, context: context, stack: [])
        let activeDriver = try SessionService.requireDriverLock(paths: paths)
        let bootstrapVars = try resolveVars(rawVars: flow.vars, inheritedVars: options.externalVars)
        let flowApp = try flow.app.map { try resolveTemplates($0, vars: bootstrapVars) } as? String
        let needLog = try flow.needLog.map { try resolveTemplates($0, vars: bootstrapVars) }
        let needNSLog = try flow.needNSLog.map { try resolveTemplates($0, vars: bootstrapVars) }
        let shouldCaptureAppLog = try appLogEnabled(needLog)
        if shouldCaptureAppLog, flowApp?.isEmpty != false {
            throw CLIParseError.invalidValue("needLog requires top-level app")
        }
        let interruptMonitor = InterruptMonitor()
        interruptMonitor.start()
        defer { interruptMonitor.stop() }

        var appLogCapture: AppLogCaptureTarget?
        var nslogCapture: NSLogCaptureTarget?
        defer {
            if let nslogCapture {
                NSLogService.stopCapture(nslogCapture, paths: paths)
            }
        }
        let captureOutput = outputSink == nil
        var bootstrapOutput = ""
        let emit: (String) -> Void = { text in
            if captureOutput {
                bootstrapOutput += text
            }
            outputSink?(text)
        }
        emit("Executing flow...\n")
        if let options = try nsloggerOptions(needNSLog) {
            let capture = try NSLogService.startFlowCapture(options: options, paths: paths)
            nslogCapture = capture
            if let port = capture.port {
                emit("  → nslog: listening on port \(port)\n")
            }
        }
        let driver = RecoveringFlowDriver(paths: paths, verbose: options.verbose)
        defer { driver.close() }
        if let flowApp, !flowApp.isEmpty {
            if shouldCaptureAppLog {
                let result = try AppLogCaptureService.start(bundleID: flowApp, udid: activeDriver.udid, deviceType: activeDriver.deviceType, paths: paths)
                appLogCapture = AppLogCaptureService.readState(paths: paths)?.lastCapture
                emit("  → log: capturing \(flowApp)")
                if let logFile = appLogCapture?.logFile {
                    emit(" → \(logFile)")
                }
                emit("\n")
                if appLogCapture == nil {
                    emit("\(result.message)\n")
                }
            } else {
                _ = try DriverCommandExecutor.execute(action: .terminateApp(bundleId: flowApp), paths: paths, hostDeviceTypeHint: activeDriver.deviceType) { body in
                    try body(driver)
                }
                _ = try DriverCommandExecutor.execute(action: .activateApp(bundleId: flowApp), paths: paths, hostDeviceTypeHint: activeDriver.deviceType) { body in
                    try body(driver)
                }
            }
        }
        var runner = FlowRunner(
            paths: paths,
            driver: driver,
            udid: activeDriver.udid,
            deviceType: activeDriver.deviceType,
            context: context,
            inheritedFlowApp: flowApp,
            outputSink: outputSink,
            captureOutput: captureOutput,
            interruptMonitor: interruptMonitor
        )
        runner.output = bootstrapOutput
        runner.appLogCapture = appLogCapture
        runner.nslogCapture = nslogCapture
        if let capture = nslogCapture {
            runner.emit("Waiting for app to connect to NSLogger...\n")
            runner.emit(try waitForNSLoggerConnection(capture: capture, timeoutMilliseconds: IOSUseProtocol.flowNSLogConnectTimeoutMilliseconds, interruptMonitor: interruptMonitor))
        }
        _ = try runner.run(file: resolvedFile, inheritedVars: options.externalVars, stack: [])
        return runner.output
    }

    static func runForTesting(file: String, externalVars: [String: Any] = [:], paths: IOSUsePaths, driver: FlowDriver, udid: String? = nil) throws -> (stdout: String, outputs: [String: Any]) {
        let context = FlowRunContext()
        try compileFlow(file: file, context: context, stack: [])
        var runner = FlowRunner(paths: paths, driver: driver, udid: udid, deviceType: nil, context: context)
        let outputs = try runner.run(file: file, inheritedVars: externalVars, stack: [])
        return (runner.output, outputs)
    }

    static func runForTesting(file: String, externalVars: [String: Any] = [:], paths: IOSUsePaths, driver: FlowDriver, udid: String? = nil, deviceType: String?) throws -> (stdout: String, outputs: [String: Any]) {
        let context = FlowRunContext()
        try compileFlow(file: file, context: context, stack: [])
        var runner = FlowRunner(paths: paths, driver: driver, udid: udid, deviceType: deviceType, context: context)
        let outputs = try runner.run(file: file, inheritedVars: externalVars, stack: [])
        return (runner.output, outputs)
    }

    static func runForTesting(file: String, externalVars: [String: Any] = [:], paths: IOSUsePaths, driver: FlowDriver, udid: String? = nil, nsloggerServer: NSLoggerServer) throws -> (stdout: String, outputs: [String: Any]) {
        let context = FlowRunContext()
        try compileFlow(file: file, context: context, stack: [])
        var runner = FlowRunner(paths: paths, driver: driver, udid: udid, deviceType: nil, context: context, nsloggerServer: nsloggerServer)
        let outputs = try runner.run(file: file, inheritedVars: externalVars, stack: [])
        return (runner.output, outputs)
    }

    static func runForTesting(file: String, externalVars: [String: Any] = [:], paths: IOSUsePaths, driver: FlowDriver, udid: String? = nil, nslogCapture: NSLogCaptureTarget) throws -> (stdout: String, outputs: [String: Any]) {
        let context = FlowRunContext()
        try compileFlow(file: file, context: context, stack: [])
        var runner = FlowRunner(paths: paths, driver: driver, udid: udid, deviceType: nil, context: context, nslogCapture: nslogCapture)
        let outputs = try runner.run(file: file, inheritedVars: externalVars, stack: [])
        return (runner.output, outputs)
    }

    static func compileForTesting(file: String) throws {
        let context = FlowRunContext()
        try compileFlow(file: file, context: context, stack: [])
    }
}

private struct FlowFile {
    var name: String
    var app: Any?
    var needLog: Any?
    var needNSLog: Any?
    var vars: [String: Any]
    var outputs: Any?
    var steps: [[String: Any]]
}

private struct CompiledFlow {
    var file: FlowFile
    var steps: [CompiledStep]
}

private struct CompiledStep {
    var action: String
    var raw: [String: Any]
    var outputs: [String]
    var cli: CompiledCLIBackedStep?
    var flowOnly: FlowOnlyAction?
}

private struct CompiledCLIBackedStep {
    var actionName: String
    var rawFields: [String: Any]
    var containsTemplates: Bool
}

private enum FlowOnlyAction {
    case runFlow
    case returnIf
    case sleep
}

private final class FlowRunContext {
    var flowCache: [String: FlowFile] = [:]
    var compiledFlows: [String: CompiledFlow] = [:]
}

private struct FlowRunner {
    let paths: IOSUsePaths
    let driver: FlowDriver
    let udid: String?
    let deviceType: String?
    let context: FlowRunContext
    var inheritedFlowApp: String? = nil
    var outputSink: FlowService.OutputSink? = nil
    var captureOutput = true
    var interruptMonitor: InterruptMonitor? = nil
    var output = ""
    var appLogCapture: AppLogCaptureTarget?
    var nsloggerServer: NSLoggerServer?
    var nslogCapture: NSLogCaptureTarget?

    mutating func emit(_ text: String) {
        if captureOutput {
            output += text
        }
        outputSink?(text)
    }

    mutating func run(file: String, inheritedVars: [String: Any], stack: [String]) throws -> [String: Any] {
        try throwIfInterrupted()
        let resolvedFile = URL(fileURLWithPath: file).standardized.path
        guard FileManager.default.fileExists(atPath: resolvedFile) else {
            throw CLIParseError.invalidValue("Flow file not found: \(file)")
        }
        if stack.contains(resolvedFile) {
            throw CLIParseError.invalidValue("runFlow cycle detected: \((stack + [resolvedFile]).joined(separator: " -> "))")
        }

        let compiled = try context.compiledFlows[resolvedFile] ?? compileFlow(file: resolvedFile, context: context, stack: stack)
        let flow = compiled.file
        var flowVars = try resolveVars(rawVars: flow.vars, inheritedVars: inheritedVars)
        let resolvedFlowApp = try flow.app.map { try resolveTemplates($0, vars: flowVars) } as? String
        let flowApp = resolvedFlowApp?.isEmpty == false ? resolvedFlowApp : inheritedFlowApp
        let needLog = try flow.needLog.map { try resolveTemplates($0, vars: flowVars) }
        _ = try appLogEnabled(needLog)
        let needNSLog = try flow.needNSLog.map { try resolveTemplates($0, vars: flowVars) }
        _ = try nsloggerOptions(needNSLog)
        let visibleStepCount = compiled.steps.reduce(0) { count, step in
            count + (isInvisibleFlowStep(step.raw) ? 0 : 1)
        }
        emit("Running flow: \(flow.name) (\(visibleStepCount) steps)\n")

        let nextStack = stack + [resolvedFile]
        var visibleStepIndex = 0
        for compiledStep in compiled.steps {
            try throwIfInterrupted()
            let rawStep = compiledStep.raw
            let resolved = try resolveTemplates(rawStep, vars: flowVars) as? [String: Any] ?? rawStep
            let isVisible = !isInvisibleFlowStep(resolved)
            if isVisible {
                visibleStepIndex += 1
                emit("Step \(visibleStepIndex)/\(visibleStepCount): \(flowStepLabel(resolved))\n")
            }
            do {
                if try runStep(compiledStep, resolvedStep: resolved, baseFile: resolvedFile, flowApp: flowApp, flowVars: &flowVars, stack: nextStack) {
                    break
                }
            } catch {
                if isVisible {
                    throw CLIParseError.invalidValue("Step \(visibleStepIndex) [action: \(compiledStep.action)] failed: \(error)")
                }
                throw error
            }
        }

        emit("Flow completed: \(visibleStepIndex) steps executed\n")
        return try collectFlowOutputs(flow.outputs, vars: flowVars)
    }

    private mutating func runStep(_ compiled: CompiledStep, resolvedStep step: [String: Any], baseFile: String, flowApp: String?, flowVars: inout [String: Any], stack: [String]) throws -> Bool {
        try throwIfInterrupted()
        let rawStep = compiled.raw
        let action = compiled.action
        if !["dom", "runFlow", "swipe"].contains(action), !compiled.outputs.isEmpty {
            throw CLIParseError.invalidValue("\(action) does not support outputs")
        }
        switch action {
        case "returnIf":
            guard rawStep.keys.contains("value") else {
                throw CLIParseError.invalidValue("returnIf requires \"value\"")
            }
            guard isAllowedReturnMatcher(step["is"]) else {
                throw CLIParseError.invalidValue("returnIf requires \"is\" to be true, false, or null")
            }
            if flowValuesEqual(step["value"], step["is"]) {
                emit("returnIf matched is=\(formatReturnMatcher(step["is"])), returning current flow\n")
                return true
            }

        case "sleep":
            let ms = try optionalInt(step["ms"], field: "sleep.ms") ?? IOSUseProtocol.flowDefaultSleepMilliseconds
            let maxSleepMilliseconds = Int(UInt32.max / UInt32(IOSUseProtocol.microsecondsPerMillisecond))
            guard ms <= maxSleepMilliseconds else {
                throw CLIParseError.invalidValue("sleep.ms is too large")
            }
            try interruptibleSleep(milliseconds: ms)

        case "runFlow":
            let childFileValue = try requiredString(step["file"], field: "runFlow.file")
            let childFile = resolveChildFile(childFileValue, baseFile: baseFile)
            let childFlow = try cachedFlowFile(childFile)
            let requested = compiled.outputs
            let declared = try outputNames(childFlow.outputs, fieldName: "flow outputs", allowMultiple: true)
            for name in requested where !declared.contains(name) {
                throw CLIParseError.invalidValue("runFlow requested undeclared output \"\(name)\" from \(childFile)")
            }
            let childVarsRaw = step["vars"] as? [String: Any] ?? [:]
            let childVars = try resolveTemplates(childVarsRaw, vars: flowVars) as? [String: Any] ?? childVarsRaw
            var child = FlowRunner(
                paths: paths,
                driver: driver,
                udid: udid,
                deviceType: deviceType,
                context: context,
                inheritedFlowApp: flowApp,
                outputSink: outputSink,
                captureOutput: outputSink == nil,
                interruptMonitor: interruptMonitor
            )
            child.nsloggerServer = nsloggerServer
            child.nslogCapture = nslogCapture
            child.appLogCapture = appLogCapture
            let childOutputs = try child.run(file: childFile, inheritedVars: flowVars.merging(childVars) { _, new in new }, stack: stack)
            if outputSink == nil {
                output += child.output
            }
            for name in requested {
                flowVars[name] = childOutputs[name] ?? NSNull()
            }

        case "nslog":
            let parsed = try FlowLowering.parseCLIBackedStep(step, flowApp: flowApp, hostUdid: udid)
            guard case .nslog(var options) = parsed else {
                throw CLIParseError.invalidValue("internal error: expected nslog command")
            }
            if !isNull(step["name"]) {
                options.name = try requiredString(step["name"], field: "nslog.name")
            }
            emit(try runNSLogStep(options))

        case "log":
            let parsed = try FlowLowering.parseCLIBackedStep(step, flowApp: flowApp, hostUdid: udid)
            guard case .logRead(let options) = parsed else {
                throw CLIParseError.invalidValue("internal error: expected log command")
            }
            let name = isNull(step["name"]) ? nil : try requiredString(step["name"], field: "log.name")
            emit(try runLogStep(options, name: name))

        case "open":
            let parsed = try FlowLowering.parseCLIBackedStep(step, flowApp: flowApp, hostUdid: udid)
            guard case .open(let options) = parsed else {
                throw CLIParseError.invalidValue("internal error: expected open command")
            }
            let validatedURL = try OpenURLService.validatedURL(options.url)
            let result = try OpenURLService.openHostSideIfAvailable(
                url: validatedURL,
                udid: options.session.udid,
                deviceType: deviceType,
                paths: paths
            ) ?? OpenURLService.openHostSideIfAvailable(url: validatedURL, session: options.session, paths: paths)
            guard let result else {
                throw CLIParseError.invalidValue("open target is unavailable. Pass a USB real device UDID, pass a booted Simulator UDID, or run `ios-use start` first.")
            }
            emit("\(result.message)\n")

        case "oslog":
            let parsed = try FlowLowering.parseCLIBackedStep(step, flowApp: flowApp, hostUdid: udid)
            guard case .oslog(let options) = parsed else {
                throw CLIParseError.invalidValue("internal error: expected oslog command")
            }
            emit(try OSLogCommandService.run(options: options, paths: paths, hostDeviceTypeHint: deviceType))

        default:
            let parsed = try FlowLowering.parseCLIBackedStep(step, flowApp: flowApp, hostUdid: udid)
            guard case .driver(let driverAction) = parsed else {
                throw CLIParseError.invalidValue("unsupported flow action: \(action)")
            }
            let result = try DriverCommandExecutor.execute(action: driverAction, paths: paths, hostDeviceTypeHint: deviceType) { body in
                try body(driver)
            }
            emit(result.stdout)
            try bindDriverOutput(result.payload, action: action, outputs: compiled.outputs, resolvedStep: step, vars: &flowVars)
        }
        return false
    }

    private mutating func runLogStep(_ options: AppLogReadOptions, name: String?) throws -> String {
        guard let capture = appLogCapture else {
            throw CLIParseError.invalidValue("log requires needLog in flow config")
        }
        let startedAt = Date()
        let refreshed = AppLogCaptureService.readState(paths: paths)?.lastCapture
        let status = refreshed?.logFile == capture.logFile ? refreshed?.status ?? capture.status : capture.status
        let output = try LogFileReadService.read(
            logFile: capture.logFile,
            status: status,
            missingFileMessage: "App log capture file not found: \(capture.logFile). Run flow again with needLog: true.",
            pattern: options.pattern,
            flags: options.flags,
            timeout: options.timeout ?? 0,
            clearAfterRead: options.clearAfterRead,
            last: options.last,
            interruptMonitor: interruptMonitor
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let path = try saveLog(lines: lines, name: name ?? "log-\(flowTimestamp())", defaultName: "log-\(flowTimestamp())")
        let summary: String
        if let pattern = options.pattern, !pattern.isEmpty {
            summary = "\(lines.count) matched /\(pattern)/"
        } else {
            summary = "\(lines.count) lines"
        }
        var out = "  → log: \(summary) in \(elapsedMs)ms → \(path)\n"
        if options.clearAfterRead {
            out += "  → log: buffer cleared\n"
        }
        return out
    }

    private mutating func runNSLogStep(_ options: NSLogOptions) throws -> String {
        guard nslogCapture != nil || nsloggerServer != nil else {
            throw CLIParseError.invalidValue("nslog requires needNSLog in flow config")
        }
        guard let pattern = options.pattern, !pattern.isEmpty else {
            throw CLIParseError.invalidValue("nslog requires pattern")
        }
        let startedAt = Date()
        let matches: [String]
        if let nslogCapture {
            let output = try NSLogService.readCapture(
                capture: nslogCapture,
                pattern: pattern,
                flags: options.flags,
                timeout: options.timeout ?? 0,
                clearAfterRead: options.clearAfterRead,
                last: nil,
                interruptMonitor: interruptMonitor
            )
            matches = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        } else if let nsloggerServer {
            matches = try waitForNSLogMatches(server: nsloggerServer, pattern: pattern, flags: options.flags, timeout: options.timeout ?? 0, interruptMonitor: interruptMonitor)
            if options.clearAfterRead {
                nsloggerServer.clear()
            }
        } else {
            matches = []
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let path = try saveLog(lines: matches, name: options.name ?? "nslog-\(flowTimestamp())", defaultName: "nslog-\(flowTimestamp())")
        var out = "  → nslog: \(matches.count) matched /\(pattern)/ in \(elapsedMs)ms → \(path)\n"
        if options.clearAfterRead {
            out += "  → nslog: buffer cleared\n"
        }
        return out
    }

    private func bindDriverOutput(_ payload: DriverCommandPayload?, action: String, outputs: [String], resolvedStep: [String: Any], vars: inout [String: Any]) throws {
        guard let name = outputs.first else { return }
        let value: Any?
        switch (action, payload) {
        case ("dom", .dom(let payload)):
            let candidates = try optionalStringList(resolvedStep["candidates"], field: "dom.candidates")
            value = domOutput(payload, candidates: candidates)
        case ("swipe", .swipe(let payload)):
            value = swipeOutput(payload)
        default:
            value = nil
        }
        vars[name] = value ?? NSNull()
    }

    private func throwIfInterrupted() throws {
        try interruptMonitor?.throwIfInterrupted()
    }

    private func interruptibleSleep(milliseconds: Int) throws {
        var remaining = milliseconds
        while remaining > 0 {
            try throwIfInterrupted()
            let chunk = min(remaining, IOSUseProtocol.flowNSLogConnectPollMilliseconds)
            usleep(useconds_t(chunk * IOSUseProtocol.microsecondsPerMillisecond))
            remaining -= chunk
        }
        try throwIfInterrupted()
    }

    private func resolveChildFile(_ file: String, baseFile: String) -> String {
        let base = URL(fileURLWithPath: baseFile).deletingLastPathComponent()
        return URL(fileURLWithPath: file, relativeTo: base).standardized.path
    }

    private func saveLog(lines: [String], name: String, defaultName: String) throws -> String {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: defaultName, extension: "log")
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func cachedFlowFile(_ path: String) throws -> FlowFile {
        if let cached = context.flowCache[path] {
            return cached
        }
        let flow = try loadFlowFile(path)
        context.flowCache[path] = flow
        return flow
    }
}

private func loadFlowFile(_ path: String) throws -> FlowFile {
    let yaml = try String(contentsOfFile: path)
    guard let raw = try Yams.load(yaml: yaml) as? [String: Any] else {
        throw CLIParseError.invalidValue("Invalid flow file: \(path) — must be a YAML object")
    }
    guard let steps = raw["steps"] as? [[String: Any]] else {
        throw CLIParseError.invalidValue("Invalid flow file: \(path) — missing required \"steps\" array field")
    }
    return FlowFile(
        name: raw["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent,
        app: raw["app"],
        needLog: raw["needLog"],
        needNSLog: raw["needNSLog"],
        vars: raw["vars"] as? [String: Any] ?? [:],
        outputs: raw["outputs"],
        steps: steps
    )
}

private let flowStepGlobalKeys: Set<String> = ["action", "comment"]

private let flowStepAllowedKeys: [String: Set<String>] = [
    "waitFor": ["label", "timeout", "traits", "cindex"],
    "dom": ["raw", "fresh", "candidates", "outputs"],
    "tap": ["label", "offset", "offsetRatio", "traits", "cindex", "dom"],
    "longpress": ["label", "duration", "traits", "cindex", "dom"],
    "input": ["tap", "content", "delete", "enter", "traits", "cindex", "dom"],
    "swipe": ["dir", "from", "to", "distance", "traits", "cindex", "outputs", "dom"],
    "screenshot": ["name"],
    "activateApp": ["bundleId"],
    "terminateApp": ["bundleId"],
    "home": [],
    "open": ["url"],
    "dismissAlert": ["index"],
    "oslog": ["pattern", "flags", "process", "pid", "timeout"],
    "log": ["pattern", "flags", "timeout", "clearAfterRead", "last", "name"],
    "nslog": ["pattern", "flags", "timeout", "clearAfterRead", "name"],
    "runFlow": ["file", "vars", "outputs"],
    "returnIf": ["value", "is"],
    "sleep": ["ms"],
]

private let flowOutputActions: Set<String> = ["dom", "runFlow", "swipe"]

enum FlowLowering {
    static func lowerCLIBackedStep(_ step: [String: Any], flowApp: String? = nil, hostUdid: String? = nil) throws -> [String] {
        let action = try requiredString(step["action"], field: "action")
        switch action {
        case "waitFor":
            var args = ["waitFor", "--label", try requiredString(step["label"], field: "waitFor.label")]
            args += try optionalNumberArg("--timeout", step["timeout"], field: "waitFor.timeout")
            args += try optionalStringArg("--traits", step["traits"], field: "waitFor.traits")
            args += try optionalIntArg("--cindex", step["cindex"], field: "waitFor.cindex", allowNegative: true)
            return args

        case "dom":
            var args = ["dom"]
            args += try boolFlag("--raw", step["raw"], field: "dom.raw")
            args += try boolFlag("--fresh", step["fresh"], field: "dom.fresh")
            return args

        case "tap":
            var args = ["tap"]
            args += try targetArgs(step["label"], field: "tap.label")
            args += try optionalStringArg("--offset", step["offset"], field: "tap.offset")
            args += try optionalStringArg("--offset-ratio", step["offsetRatio"], field: "tap.offsetRatio")
            args += try optionalStringArg("--traits", step["traits"], field: "tap.traits")
            args += try optionalIntArg("--cindex", step["cindex"], field: "tap.cindex", allowNegative: true)
            args += try optionalPostDomArg("--dom", step["dom"], field: "tap.dom")
            return args

        case "longpress":
            var args = ["longpress"]
            args += try targetArgs(step["label"], field: "longpress.label")
            args += try optionalIntArg("--duration", step["duration"], field: "longpress.duration", allowNegative: false)
            args += try optionalStringArg("--traits", step["traits"], field: "longpress.traits")
            args += try optionalIntArg("--cindex", step["cindex"], field: "longpress.cindex", allowNegative: true)
            args += try optionalPostDomArg("--dom", step["dom"], field: "longpress.dom")
            return args

        case "input":
            var args = ["input"]
            args += try optionalStringArg("--tap", step["tap"], field: "input.tap")
            args += ["--content", try requiredString(step["content"], field: "input.content")]
            args += try optionalIntArg("--delete", step["delete"], field: "input.delete", allowNegative: false)
            args += try boolFlag("--enter", step["enter"], field: "input.enter")
            args += try optionalStringArg("--traits", step["traits"], field: "input.traits")
            args += try optionalIntArg("--cindex", step["cindex"], field: "input.cindex", allowNegative: true)
            args += try optionalPostDomArg("--dom", step["dom"], field: "input.dom")
            return args

        case "swipe":
            var args = ["swipe"]
            args += try optionalStringArg("--to", step["to"], field: "swipe.to")
            args += try optionalStringArg("--from", step["from"], field: "swipe.from")
            args += try optionalStringArg("--dir", step["dir"], field: "swipe.dir")
            args += try optionalNumberArg("--distance", step["distance"], field: "swipe.distance")
            args += try optionalStringArg("--traits", step["traits"], field: "swipe.traits")
            args += try optionalIntArg("--cindex", step["cindex"], field: "swipe.cindex", allowNegative: true)
            args += try optionalPostDomArg("--dom", step["dom"], field: "swipe.dom")
            return args

        case "screenshot":
            var args = ["screenshot"]
            args += try optionalStringArg("--name", step["name"], field: "screenshot.name")
            return args

        case "activateApp":
            return ["activateApp", try requiredString(step["bundleId"] ?? flowApp, field: "activateApp.bundleId")]

        case "terminateApp":
            return ["terminateApp", try requiredString(step["bundleId"] ?? flowApp, field: "terminateApp.bundleId")]

        case "home":
            return ["home"]

        case "open":
            return ["open", try requiredString(step["url"], field: "open.url")]
                + hostUdidArg(hostUdid)

        case "dismissAlert":
            var args = ["dismissAlert"]
            args += try optionalIntArg("--index", step["index"], field: "dismissAlert.index", allowNegative: false)
            return args

        case "oslog":
            var args = ["oslog"]
            args += try optionalStringArg("--pattern", step["pattern"], field: "oslog.pattern")
            args += try optionalStringArg("--flags", step["flags"], field: "oslog.flags")
            args += try optionalStringArg("--process", step["process"], field: "oslog.process")
            args += try optionalIntArg("--pid", step["pid"], field: "oslog.pid", allowNegative: false)
            args += try optionalNumberArg("--timeout", step["timeout"], field: "oslog.timeout")
            args += hostUdidArg(hostUdid)
            return args

        case "log":
            var args = ["log-read"]
            args += try optionalStringArg("--pattern", step["pattern"], field: "log.pattern")
            args += try optionalStringArg("--flags", step["flags"], field: "log.flags")
            args += try optionalNumberArg("--timeout", step["timeout"], field: "log.timeout")
            args += try boolFlag("--clearAfterRead", step["clearAfterRead"], field: "log.clearAfterRead")
            args += try optionalIntArg("--last", step["last"], field: "log.last", allowNegative: false)
            return args

        case "nslog":
            var args = ["nslog", "read", "--pattern", try requiredString(step["pattern"], field: "nslog.pattern")]
            args += try optionalStringArg("--flags", step["flags"], field: "nslog.flags")
            args += try optionalNumberArg("--timeout", step["timeout"], field: "nslog.timeout")
            args += try boolFlag("--clearAfterRead", step["clearAfterRead"], field: "nslog.clearAfterRead")
            return args

        default:
            throw CLIParseError.invalidValue("unsupported flow action: \(action)")
        }
    }

    static func parseCLIBackedStep(_ step: [String: Any], flowApp: String? = nil, hostUdid: String? = nil) throws -> ParsedCommand {
        let parsed = try CLIParser.parse(lowerCLIBackedStep(step, flowApp: flowApp, hostUdid: hostUdid))
        switch parsed {
        case .appLifecycle(let options) where options.action == .activate:
            return .driver(.activateApp(bundleId: options.bundleID))
        case .appLifecycle(let options) where options.action == .terminate:
            return .driver(.terminateApp(bundleId: options.bundleID))
        default:
            return parsed
        }
    }

    static func validateStaticTypes(_ step: [String: Any]) throws {
        let action = try requiredString(step["action"], field: "action")
        switch action {
        case "waitFor":
            try validateStringLike(step["label"], field: "waitFor.label", required: true)
            try validateNumberLike(step["timeout"], field: "waitFor.timeout")
            try validateStringLike(step["traits"], field: "waitFor.traits")
            try validateIntLike(step["cindex"], field: "waitFor.cindex", allowNegative: true)
        case "dom":
            try validateBoolLike(step["raw"], field: "dom.raw")
            try validateBoolLike(step["fresh"], field: "dom.fresh")
            try validateStringListLike(step["candidates"], field: "dom.candidates")
        case "tap":
            try validateStringLike(step["label"], field: "tap.label", required: true)
            try validateStringLike(step["offset"], field: "tap.offset")
            try validateStringLike(step["offsetRatio"], field: "tap.offsetRatio")
            try validateStringLike(step["traits"], field: "tap.traits")
            try validateIntLike(step["cindex"], field: "tap.cindex", allowNegative: true)
            try validatePostDomLike(step["dom"], field: "tap.dom")
        case "longpress":
            try validateStringLike(step["label"], field: "longpress.label", required: true)
            try validateIntLike(step["duration"], field: "longpress.duration", allowNegative: false)
            try validateStringLike(step["traits"], field: "longpress.traits")
            try validateIntLike(step["cindex"], field: "longpress.cindex", allowNegative: true)
            try validatePostDomLike(step["dom"], field: "longpress.dom")
        case "input":
            try validateStringLike(step["tap"], field: "input.tap")
            try validateStringLike(step["content"], field: "input.content", required: true)
            try validateIntLike(step["delete"], field: "input.delete", allowNegative: false)
            try validateBoolLike(step["enter"], field: "input.enter")
            try validateStringLike(step["traits"], field: "input.traits")
            try validateIntLike(step["cindex"], field: "input.cindex", allowNegative: true)
            try validatePostDomLike(step["dom"], field: "input.dom")
        case "swipe":
            try validateStringLike(step["to"], field: "swipe.to")
            try validateStringLike(step["from"], field: "swipe.from")
            try validateStringLike(step["dir"], field: "swipe.dir")
            try validateNumberLike(step["distance"], field: "swipe.distance")
            try validateStringLike(step["traits"], field: "swipe.traits")
            try validateIntLike(step["cindex"], field: "swipe.cindex", allowNegative: true)
            try validatePostDomLike(step["dom"], field: "swipe.dom")
        case "screenshot":
            try validateStringLike(step["name"], field: "screenshot.name")
        case "activateApp":
            try validateStringLike(step["bundleId"], field: "activateApp.bundleId")
        case "terminateApp":
            try validateStringLike(step["bundleId"], field: "terminateApp.bundleId")
        case "home":
            break
        case "open":
            try validateStringLike(step["url"], field: "open.url", required: true)
        case "dismissAlert":
            try validateIntLike(step["index"], field: "dismissAlert.index", allowNegative: false)
        case "oslog":
            try validateStringLike(step["pattern"], field: "oslog.pattern")
            try validateStringLike(step["flags"], field: "oslog.flags")
            try validateStringLike(step["process"], field: "oslog.process")
            try validateIntLike(step["pid"], field: "oslog.pid", allowNegative: false)
            if !isNull(step["process"]), !isNull(step["pid"]) {
                throw CLIParseError.invalidValue("oslog.process and oslog.pid are mutually exclusive")
            }
            try validatePositiveNumberLike(step["timeout"], field: "oslog.timeout")
        case "log":
            try validateStringLike(step["pattern"], field: "log.pattern")
            try validateStringLike(step["flags"], field: "log.flags")
            try validateNumberLike(step["timeout"], field: "log.timeout")
            try validateBoolLike(step["clearAfterRead"], field: "log.clearAfterRead")
            try validatePositiveIntLike(step["last"], field: "log.last")
            try validateStringLike(step["name"], field: "log.name")
        case "nslog":
            try validateStringLike(step["pattern"], field: "nslog.pattern", required: true)
            try validateStringLike(step["flags"], field: "nslog.flags")
            try validateNumberLike(step["timeout"], field: "nslog.timeout")
            try validateBoolLike(step["clearAfterRead"], field: "nslog.clearAfterRead")
            try validateStringLike(step["name"], field: "nslog.name")
        default:
            break
        }
    }

    private static func targetArgs(_ value: Any?, field: String) throws -> [String] {
        [try requiredString(value, field: field)]
    }

    private static func optionalStringArg(_ flag: String, _ value: Any?, field: String) throws -> [String] {
        guard !isNull(value) else { return [] }
        return [flag, try requiredString(value, field: field)]
    }

    private static func optionalNumberArg(_ flag: String, _ value: Any?, field: String) throws -> [String] {
        guard !isNull(value) else { return [] }
        return [flag, try numberString(value, field: field)]
    }

    private static func optionalIntArg(_ flag: String, _ value: Any?, field: String, allowNegative: Bool) throws -> [String] {
        guard !isNull(value) else { return [] }
        return [flag, try intString(value, field: field, allowNegative: allowNegative)]
    }

    private static func optionalPostDomArg(_ flag: String, _ value: Any?, field: String) throws -> [String] {
        guard !isNull(value) else { return [] }
        let string = try intString(value, field: field, allowNegative: false)
        let milliseconds = Int(string) ?? 0
        guard milliseconds >= IOSUseProtocol.minimumPostDomMilliseconds else {
            throw CLIParseError.invalidValue("\(field) must be at least \(IOSUseProtocol.minimumPostDomMilliseconds)ms")
        }
        return [flag, String(milliseconds)]
    }

    private static func boolFlag(_ flag: String, _ value: Any?, field: String) throws -> [String] {
        guard !isNull(value) else { return [] }
        guard let bool = value as? Bool else {
            throw CLIParseError.invalidValue("\(field) must be a boolean")
        }
        return bool ? [flag] : []
    }

    private static func hostUdidArg(_ udid: String?) -> [String] {
        guard let udid, !udid.isEmpty else { return [] }
        return ["--udid", udid]
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let string = value as? String, !string.isEmpty else {
            throw CLIParseError.invalidValue("\(field) must be a string")
        }
        return string
    }

    private static func numberString(_ value: Any?, field: String) throws -> String {
        let parsed: Double?
        if let double = value as? Double {
            parsed = double
        } else if let int = value as? Int {
            parsed = Double(int)
        } else if let int32 = value as? Int32 {
            parsed = Double(int32)
        } else {
            parsed = nil
        }
        guard let parsed, parsed.isFinite else {
            throw CLIParseError.invalidValue("\(field) must be a finite number")
        }
        return String(parsed)
    }

    private static func intString(_ value: Any?, field: String, allowNegative: Bool) throws -> String {
        let parsed: Int?
        if let int = value as? Int {
            parsed = int
        } else if let int32 = value as? Int32 {
            parsed = Int(int32)
        } else if let double = value as? Double, double.isFinite, double.rounded(.towardZero) == double {
            parsed = Int(exactly: double)
        } else {
            parsed = nil
        }
        guard let parsed else {
            throw CLIParseError.invalidValue("\(field) must be an integer")
        }
        if !allowNegative, parsed < 0 {
            throw CLIParseError.invalidValue("\(field) must be non-negative")
        }
        return String(parsed)
    }

    private static func validateStringLike(_ value: Any?, field: String, required: Bool = false) throws {
        if isNull(value) {
            if required { throw CLIParseError.invalidValue("\(field) must be a string") }
            return
        }
        guard value is String else {
            throw CLIParseError.invalidValue("\(field) must be a string")
        }
    }

    private static func validateNumberLike(_ value: Any?, field: String) throws {
        guard !isNull(value), !containsTemplate(value) else { return }
        _ = try numberString(value, field: field)
    }

    private static func validatePositiveNumberLike(_ value: Any?, field: String) throws {
        guard !isNull(value), !containsTemplate(value) else { return }
        let string = try numberString(value, field: field)
        guard let parsed = Double(string), parsed > 0 else {
            throw CLIParseError.invalidValue("\(field) must be greater than 0")
        }
    }

    private static func validateIntLike(_ value: Any?, field: String, allowNegative: Bool) throws {
        guard !isNull(value), !containsTemplate(value) else { return }
        _ = try intString(value, field: field, allowNegative: allowNegative)
    }

    private static func validatePositiveIntLike(_ value: Any?, field: String) throws {
        guard !isNull(value), !containsTemplate(value) else { return }
        let string = try intString(value, field: field, allowNegative: false)
        guard let parsed = Int(string), parsed > 0 else {
            throw CLIParseError.invalidValue("\(field) must be greater than 0")
        }
    }

    private static func validatePostDomLike(_ value: Any?, field: String) throws {
        guard !isNull(value), !containsTemplate(value) else { return }
        let string = try intString(value, field: field, allowNegative: false)
        let milliseconds = Int(string) ?? 0
        guard milliseconds >= IOSUseProtocol.minimumPostDomMilliseconds else {
            throw CLIParseError.invalidValue("\(field) must be at least \(IOSUseProtocol.minimumPostDomMilliseconds)ms")
        }
    }

    private static func validateBoolLike(_ value: Any?, field: String) throws {
        guard !isNull(value), !containsTemplate(value) else { return }
        guard value is Bool else {
            throw CLIParseError.invalidValue("\(field) must be a boolean")
        }
    }

    private static func validateStringListLike(_ value: Any?, field: String) throws {
        guard !isNull(value), !containsTemplate(value) else { return }
        guard let list = value as? [Any] else {
            throw CLIParseError.invalidValue("\(field) must be a string array")
        }
        for item in list {
            guard let string = item as? String, !string.isEmpty else {
                throw CLIParseError.invalidValue("\(field) must contain only non-empty strings")
            }
        }
    }
}

@discardableResult
private func compileFlow(file: String, context: FlowRunContext, stack: [String]) throws -> CompiledFlow {
    let resolvedFile = URL(fileURLWithPath: file).standardized.path
    if let compiled = context.compiledFlows[resolvedFile] {
        return compiled
    }
    guard FileManager.default.fileExists(atPath: resolvedFile) else {
        throw CLIParseError.invalidValue("Flow file not found: \(file)")
    }
    if stack.contains(resolvedFile) {
        throw CLIParseError.invalidValue("runFlow cycle detected: \((stack + [resolvedFile]).joined(separator: " -> "))")
    }

    let flow = try cachedFlowFile(resolvedFile, context: context)
    _ = try outputNames(flow.outputs, fieldName: "flow outputs", allowMultiple: true)
    if let vars = flow.vars as Any?, !(vars is [String: Any]) {
        throw CLIParseError.invalidValue("flow vars must be an object")
    }
    try validateNeedNSLogForCompile(flow.needNSLog)
    try validateNeedLogForCompile(flow.needLog)

    let nextStack = stack + [resolvedFile]
    var compiledSteps: [CompiledStep] = []
    compiledSteps.reserveCapacity(flow.steps.count)
    for (index, step) in flow.steps.enumerated() {
        compiledSteps.append(try compileFlowStep(step, index: index + 1, baseFile: resolvedFile, context: context, stack: nextStack))
    }
    let compiled = CompiledFlow(file: flow, steps: compiledSteps)
    context.compiledFlows[resolvedFile] = compiled
    return compiled
}

private func cachedFlowFile(_ path: String, context: FlowRunContext) throws -> FlowFile {
    let resolved = URL(fileURLWithPath: path).standardized.path
    if let cached = context.flowCache[resolved] {
        return cached
    }
    let flow = try loadFlowFile(resolved)
    context.flowCache[resolved] = flow
    return flow
}

private func compileFlowStep(_ step: [String: Any], index: Int, baseFile: String, context: FlowRunContext, stack: [String]) throws -> CompiledStep {
    let action = try requiredStaticString(step["action"], field: "step \(index).action")
    guard let allowed = flowStepAllowedKeys[action] else {
        throw CLIParseError.invalidValue("unsupported flow action: \(action)")
    }

    if hasOutputs(step["outputs"]), !flowOutputActions.contains(action) {
        throw CLIParseError.invalidValue("\(action) does not support outputs")
    }

    let allowedKeys = allowed.union(flowStepGlobalKeys)
    for key in step.keys where !allowedKeys.contains(key) {
        throw CLIParseError.invalidValue("\(action) has unknown field \"\(key)\"")
    }

    if !["runFlow", "returnIf", "sleep"].contains(action) {
        try FlowLowering.validateStaticTypes(step)
        let outputs: [String]
        switch action {
        case "dom":
            outputs = try outputNames(step["outputs"], fieldName: "dom outputs", allowMultiple: false)
        case "swipe":
            outputs = try outputNames(step["outputs"], fieldName: "swipe outputs", allowMultiple: false)
        default:
            outputs = []
            break
        }
        let lifecycleNeedsFlowApp = ["activateApp", "terminateApp"].contains(action) && isNull(step["bundleId"])
        let cliFieldsContainTemplates = containsTemplateInActionFields(step, action: action)
        if !cliFieldsContainTemplates, !lifecycleNeedsFlowApp {
            let parsed = try FlowLowering.parseCLIBackedStep(step)
            if case .driver(let driverAction) = parsed {
                try DriverCommandExecutor.validate(action: driverAction)
            }
        }
        return CompiledStep(
            action: action,
            raw: step,
            outputs: outputs,
            cli: CompiledCLIBackedStep(actionName: action, rawFields: step, containsTemplates: cliFieldsContainTemplates),
            flowOnly: nil
        )
    }

    switch action {
    case "runFlow":
        let childFileValue = try requiredStaticString(step["file"], field: "runFlow.file")
        let outputs = try outputNames(step["outputs"], fieldName: "runFlow outputs", allowMultiple: true)
        guard let vars = step["vars"], !isNull(vars) else {
            try validateRunFlowOutputs(step["outputs"], childFileValue: childFileValue, baseFile: baseFile, context: context, stack: stack)
            return CompiledStep(action: action, raw: step, outputs: outputs, cli: nil, flowOnly: .runFlow)
        }
        guard vars is [String: Any] || containsTemplate(vars) else {
            throw CLIParseError.invalidValue("runFlow.vars must be an object")
        }
        try validateRunFlowOutputs(step["outputs"], childFileValue: childFileValue, baseFile: baseFile, context: context, stack: stack)
        return CompiledStep(action: action, raw: step, outputs: outputs, cli: nil, flowOnly: .runFlow)

    case "returnIf":
        guard step.keys.contains("value") else {
            throw CLIParseError.invalidValue("returnIf requires \"value\"")
        }
        if !containsTemplate(step["is"]), !isAllowedReturnMatcher(step["is"]) {
            throw CLIParseError.invalidValue("returnIf requires \"is\" to be true, false, or null")
        }
        return CompiledStep(action: action, raw: step, outputs: [], cli: nil, flowOnly: .returnIf)

    case "sleep":
        if let ms = try validateStaticInt(step["ms"], field: "sleep.ms") {
            let maxSleepMilliseconds = Int(UInt32.max / UInt32(IOSUseProtocol.microsecondsPerMillisecond))
            guard ms <= maxSleepMilliseconds else {
                throw CLIParseError.invalidValue("sleep.ms is too large")
            }
        }
        return CompiledStep(action: action, raw: step, outputs: [], cli: nil, flowOnly: .sleep)

    default:
        throw CLIParseError.invalidValue("unsupported flow action: \(action)")
    }
}

private func containsTemplateInActionFields(_ step: [String: Any], action: String) -> Bool {
    guard let fields = flowStepAllowedKeys[action] else {
        return containsTemplate(step)
    }
    return fields.contains { containsTemplate(step[$0]) }
}

private func validateRunFlowOutputs(_ rawOutputs: Any?, childFileValue: String, baseFile: String, context: FlowRunContext, stack: [String]) throws {
    let requested = try outputNames(rawOutputs, fieldName: "runFlow outputs", allowMultiple: true)
    guard !containsTemplate(childFileValue) else { return }
    let childFile = URL(fileURLWithPath: childFileValue, relativeTo: URL(fileURLWithPath: baseFile).deletingLastPathComponent()).standardized.path
    try compileFlow(file: childFile, context: context, stack: stack)
    let childFlow = try cachedFlowFile(childFile, context: context)
    let declared = try outputNames(childFlow.outputs, fieldName: "flow outputs", allowMultiple: true)
    for name in requested where !declared.contains(name) {
        throw CLIParseError.invalidValue("runFlow requested undeclared output \"\(name)\" from \(childFile)")
    }
}

private func validateNeedNSLogForCompile(_ raw: Any?) throws {
    guard !isNull(raw), !containsTemplate(raw) else { return }
    _ = try nsloggerOptions(raw)
}

private func validateNeedLogForCompile(_ raw: Any?) throws {
    guard !isNull(raw), !containsTemplate(raw) else { return }
    _ = try appLogEnabled(raw)
}

private func appLogEnabled(_ raw: Any?) throws -> Bool {
    guard !isNull(raw) else { return false }
    guard let enabled = raw as? Bool else {
        throw CLIParseError.invalidValue("needLog must be a boolean")
    }
    return enabled
}

private func nsloggerOptions(_ raw: Any?) throws -> NSLoggerServerOptions? {
    guard !isNull(raw) else { return nil }
    if let enabled = raw as? Bool {
        return enabled ? NSLoggerServerOptions() : nil
    }
    guard let dict = raw as? [String: Any] else {
        throw CLIParseError.invalidValue("needNSLog must be a boolean or object")
    }
    if bool(dict["enabled"]) == false, dict.keys.contains("enabled") {
        return nil
    }
    if dict["port"] != nil || dict["ssl"] != nil {
        throw CLIParseError.invalidValue("needNSLog does not support port or ssl configuration; NSLogger always uses TLS and an internal random port")
    }
    return NSLoggerServerOptions(
        name: optionalString(dict["name"]),
        publishBonjour: dict.keys.contains("publishBonjour") ? bool(dict["publishBonjour"]) : true,
        maxBufferSize: try positiveInt(dict["maxBufferSize"], field: "needNSLog.maxBufferSize") ?? IOSUseProtocol.nsloggerDefaultBufferSize
    )
}

private func waitForNSLogMatches(server: NSLoggerServer, pattern: String, flags: String, timeout: Double, interruptMonitor: InterruptMonitor? = nil) throws -> [String] {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    let regex = try NSRegularExpression(pattern: pattern, options: try NSLogService.regexOptions(flags))
    var cursor = 0
    repeat {
        try interruptMonitor?.throwIfInterrupted()
        let result = server.grep(regex: regex, from: cursor)
        cursor = result.nextIndex
        let matches = result.matches
        if !matches.isEmpty || timeout <= 0 {
            return matches
        }
        usleep(useconds_t(IOSUseProtocol.flowNSLogConnectPollMilliseconds * IOSUseProtocol.microsecondsPerMillisecond))
    } while Date() < deadline
    try interruptMonitor?.throwIfInterrupted()
    return server.grep(regex: regex, from: cursor).matches
}

private func waitForNSLoggerConnection(capture: NSLogCaptureTarget, timeoutMilliseconds: Int, interruptMonitor: InterruptMonitor? = nil) throws -> String {
    let startedAt = Date()
    let timeoutSeconds = Double(max(0, timeoutMilliseconds)) / 1000.0
    while Date().timeIntervalSince(startedAt) < timeoutSeconds {
        try interruptMonitor?.throwIfInterrupted()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: capture.logFile),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 0 {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            return "App connected to NSLogger (\(elapsedMs)ms)\n"
        }
        usleep(useconds_t(IOSUseProtocol.flowNSLogConnectPollMilliseconds * IOSUseProtocol.microsecondsPerMillisecond))
    }
    try interruptMonitor?.throwIfInterrupted()
    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    return "Timeout waiting for app to connect to NSLogger after \(elapsedMs)ms, continuing...\n"
}

private func flowTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"[:.]"#, with: "-", options: .regularExpression)
}

private func resolveVars(rawVars: [String: Any], inheritedVars: [String: Any]) throws -> [String: Any] {
    var resolved = inheritedVars
    for (key, value) in rawVars where resolved[key] == nil {
        resolved[key] = try resolveTemplates(value, vars: resolved)
    }
    return resolved
}

private func resolveTemplates(_ value: Any, vars: [String: Any]) throws -> Any {
    if let string = value as? String {
        if let whole = wholeTemplateExpression(string) {
            return try readTemplateValue(whole, vars: vars)
        }
        return try replaceTemplateExpressions(in: string, vars: vars)
    }
    if let list = value as? [Any] {
        return try list.map { try resolveTemplates($0, vars: vars) }
    }
    if let dict = value as? [String: Any] {
        var out: [String: Any] = [:]
        for (key, nested) in dict {
            out[key] = try resolveTemplates(nested, vars: vars)
        }
        return out
    }
    return value
}

private func wholeTemplateExpression(_ string: String) -> String? {
    guard string.hasPrefix("${"), string.hasSuffix("}") else { return nil }
    return String(string.dropFirst(2).dropLast())
}

private func replaceTemplateExpressions(in string: String, vars: [String: Any]) throws -> String {
    guard string.contains("${") else { return string }
    let regex = FlowRegex.template
    let nsRange = NSRange(string.startIndex..<string.endIndex, in: string)
    var result = string
    for match in regex.matches(in: string, range: nsRange).reversed() {
        guard let exprRange = Range(match.range(at: 1), in: string),
              let fullRange = Range(match.range(at: 0), in: string) else { continue }
        let value = try readTemplateValue(String(string[exprRange]), vars: vars)
        result.replaceSubrange(fullRange, with: String(describing: value))
    }
    return result
}

private func readTemplateValue(_ expr: String, vars: [String: Any]) throws -> Any {
    let parts = expr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map(String.init)
    guard !parts.isEmpty else {
        throw CLIParseError.invalidValue("Invalid template expression: \"${\(expr)}\"")
    }

    var current: Any? = vars
    for (index, part) in parts.enumerated() {
        if index == 0, part == "vars" {
            current = vars
            continue
        }
        guard let dict = current as? [String: Any], let next = dict[part] else {
            throw CLIParseError.invalidValue("Missing template value: \"${\(expr)}\"")
        }
        current = next
    }
    return current ?? NSNull()
}

private func collectFlowOutputs(_ raw: Any?, vars: [String: Any]) throws -> [String: Any] {
    var out: [String: Any] = [:]
    for name in try outputNames(raw, fieldName: "flow outputs", allowMultiple: true) {
        out[name] = vars[name] ?? NSNull()
    }
    return out
}

private func outputNames(_ value: Any?, fieldName: String, allowMultiple: Bool) throws -> [String] {
    if value == nil || value is NSNull { return [] }
    let rawNames: [Any]
    if let string = value as? String {
        rawNames = [string]
    } else if let list = value as? [Any] {
        rawNames = list
    } else {
        throw CLIParseError.invalidValue("\(fieldName) must contain non-empty variable names")
    }
    if !allowMultiple, rawNames.count > 1 {
        throw CLIParseError.invalidValue("\(fieldName) must be a single variable name")
    }
    let names = rawNames.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard names.count == rawNames.count, names.allSatisfy({ !$0.isEmpty }) else {
        throw CLIParseError.invalidValue("\(fieldName) must contain non-empty variable names")
    }
    let valid = FlowRegex.outputName
    for name in names where valid.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)) == nil {
        throw CLIParseError.invalidValue("\(fieldName) contains invalid variable name: \(name)")
    }
    return names
}

private func swipeOutput(_ payload: ForySwipePayload) -> [String: Any] {
    var out: [String: Any] = [
        "scrolls": payload.scrolls,
        "scrollDirection": payload.scrollDirection,
        "element": elementSummaryObject(payload.element),
    ]
    if !payload.element.ancestors.isEmpty {
        out["ancestors"] = payload.element.ancestors
    }
    return out
}

private func domOutput(_ payload: ForyDomPayload, candidates: [String]) -> [String: Any] {
    var matches: [[String: Any]] = []
    var matchedIndexes = Set<Int>()
    let normalizedElements = payload.elements.map { element in
        [element.label, element.value]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(normalizeSearchText)
    }
    for candidate in candidates.map(normalizeSearchText).filter({ !$0.isEmpty }) {
        for (idx, element) in payload.elements.enumerated() where !matchedIndexes.contains(idx) {
            if normalizedElements[idx].contains(where: { $0.contains(candidate) }) {
                matchedIndexes.insert(idx)
                matches.append(domCandidateObject(element))
            }
        }
    }
    return [
        "dom": domObject(payload),
        "matches": matches,
        "firstMatch": matches.first ?? NSNull(),
    ]
}

private func elementSummaryObject(_ element: ForyElementSummary) -> [String: Any] {
    var out: [String: Any] = [
        "type": DriverOutput.elementTypeName(element.elemType),
        "label": element.label,
        "rect": rectObject(element.rect),
    ]
    if !element.ancestors.isEmpty {
        out["ancestors"] = element.ancestors
    }
    return out
}

private func domObject(_ payload: ForyDomPayload) -> [String: Any] {
    [
        "app": payload.app,
        "window": [payload.windowSize.x, payload.windowSize.y],
        "elements": DriverOutput.presentationDomElements(payload.elements).map(domElementObject),
        "raw": payload.raw,
    ]
}

private func domElementObject(_ element: ForyDomElement) -> [String: Any] {
    [
        "type": element.traits.first ?? "Unknown",
        "traits": element.traits,
        "childCount": element.childCount,
        "label": element.label,
        "value": element.value,
        "rect": rectObject(element.rect) as Any,
    ]
}

private func domCandidateObject(_ element: ForyDomElement) -> [String: Any] {
    var out: [String: Any] = [
        "type": element.traits.first ?? "Unknown",
        "label": element.label.isEmpty ? element.value : element.label,
    ]
    if let rect = element.rect {
        out["rect"] = [rect.x, rect.y, rect.w, rect.h]
    }
    if !element.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        out["value"] = element.value
    }
    return out
}

private func rectObject(_ rect: ForyRect?) -> Any {
    guard let rect else { return NSNull() }
    return [rect.x, rect.y, rect.w, rect.h]
}

private func normalizeSearchText(_ text: String) -> String {
    FlowRegex.searchSeparator.stringByReplacingMatches(
        in: text,
        range: NSRange(text.startIndex..<text.endIndex, in: text),
        withTemplate: ""
    ).lowercased()
}

private func isAllowedReturnMatcher(_ value: Any?) -> Bool {
    value is Bool || value == nil || value is NSNull
}

private func flowValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    if isNull(lhs), isNull(rhs) { return true }
    if let l = lhs as? Bool, let r = rhs as? Bool { return l == r }
    if let l = lhs as? String, let r = rhs as? String { return l == r }
    if let l = number(lhs), let r = number(rhs) { return l == r }
    return false
}

private func formatReturnMatcher(_ value: Any?) -> String {
    if isNull(value) { return "null" }
    return String(describing: value!)
}

private func isNull(_ value: Any?) -> Bool {
    value == nil || value is NSNull
}

private func hasOutputs(_ raw: Any?) -> Bool {
    raw != nil && !(raw is NSNull)
}

private func containsTemplate(_ value: Any?) -> Bool {
    guard let value, !isNull(value) else { return false }
    if let string = value as? String {
        return string.contains("${")
    }
    if let list = value as? [Any] {
        return list.contains { containsTemplate($0) }
    }
    if let dict = value as? [String: Any] {
        return dict.values.contains { containsTemplate($0) }
    }
    return false
}

private func requiredStaticString(_ value: Any?, field: String) throws -> String {
    guard !isNull(value) else {
        throw CLIParseError.invalidValue("\(field) must be a string")
    }
    guard let string = value as? String, !string.isEmpty else {
        throw CLIParseError.invalidValue("\(field) must be a string")
    }
    return string
}

@discardableResult
private func validateStaticInt(_ value: Any?, field: String) throws -> Int? {
    guard !isNull(value), !containsTemplate(value) else { return nil }
    let parsed: Int?
    if let int = value as? Int {
        parsed = int
    } else if let int32 = value as? Int32 {
        parsed = Int(int32)
    } else if let double = value as? Double, double.isFinite, double.rounded(.towardZero) == double {
        parsed = Int(exactly: double)
    } else {
        parsed = nil
    }
    guard let parsed else {
        throw CLIParseError.invalidValue("\(field) must be an integer")
    }
    guard parsed >= 0 else {
        throw CLIParseError.invalidValue("\(field) must be non-negative")
    }
    return parsed
}

private func requiredString(_ value: Any?, field: String) throws -> String {
    guard let string = value as? String, !string.isEmpty else {
        throw CLIParseError.invalidValue("\(field) must be a string")
    }
    return string
}

private func optionalStringList(_ value: Any?, field: String) throws -> [String] {
    guard !isNull(value) else { return [] }
    guard let list = value as? [Any] else {
        throw CLIParseError.invalidValue("\(field) must be a string array")
    }
    var strings: [String] = []
    for item in list {
        guard let string = item as? String, !string.isEmpty else {
            throw CLIParseError.invalidValue("\(field) must contain only non-empty strings")
        }
        strings.append(string)
    }
    return strings
}

private func optionalString(_ value: Any?) -> String? {
    guard !isNull(value) else { return nil }
    return value.map { String(describing: $0) }
}

private func bool(_ value: Any?) -> Bool {
    (value as? Bool) ?? false
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let int32 = value as? Int32 { return Int(int32) }
    if let double = value as? Double, double.isFinite, double.rounded(.towardZero) == double {
        return Int(exactly: double)
    }
    if let string = value as? String { return Int(string) }
    return nil
}

private func optionalInt(_ value: Any?, field: String) throws -> Int? {
    guard !isNull(value) else { return nil }
    guard let parsed = intValue(value) else {
        throw CLIParseError.invalidValue("\(field) must be an integer")
    }
    guard parsed >= 0 else {
        throw CLIParseError.invalidValue("\(field) must be non-negative")
    }
    return parsed
}

private func positiveInt(_ value: Any?, field: String) throws -> Int? {
    guard let parsed = try optionalInt(value, field: field) else { return nil }
    guard parsed > 0 else {
        throw CLIParseError.invalidValue("\(field) must be greater than 0")
    }
    return parsed
}

private func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double.isFinite ? double : nil }
    if let int = value as? Int { return Double(int) }
    if let int32 = value as? Int32 { return Double(int32) }
    if let string = value as? String, let double = Double(string), double.isFinite { return double }
    return nil
}

private func isInvisibleFlowStep(_ step: [String: Any]) -> Bool {
    (step["action"] as? String) == "sleep"
}

private func flowStepLabel(_ step: [String: Any]) -> String {
    for key in ["comment", "text", "name", "label", "action"] {
        if let value = step[key] as? String, !value.isEmpty {
            return value
        }
    }
    return "step"
}

private final class RecoveringFlowDriver: FlowDriver {
    private let session: LockedDriverClientSession

    init(paths: IOSUsePaths, verbose: Bool) {
        self.session = LockedDriverClientSession(paths: paths, verbose: verbose)
    }

    func close() {
        session.close()
    }

    private func run<T>(_ body: (DriverCommandClient) throws -> T) throws -> T {
        try session.run(body)
    }

    func activateApp(bundleId: String) throws {
        try run { try $0.activateApp(bundleId: bundleId) }
    }

    func terminateApp(bundleId: String) throws {
        try run { try $0.terminateApp(bundleId: bundleId) }
    }

    func home() throws {
        try run { try $0.home() }
    }

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        try run { try $0.dismissAlert(index: index) }
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        try run { try $0.proxyCAPush(caBase64: caBase64) }
    }

    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload {
        try run { try $0.waitFor(label: label, timeout: timeout, traits: traits, cindex: cindex) }
    }

    func dom(raw: Bool, fresh: Bool, waitQuiescence: Bool) throws -> ForyDomPayload {
        try run { try $0.dom(raw: raw, fresh: fresh, waitQuiescence: waitQuiescence) }
    }

    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload {
        try run { try $0.tap(target: target, traits: traits, cindex: cindex, offset: offset, ratio: ratio) }
    }

    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload {
        try run { try $0.longPress(target: target, durationMs: durationMs, traits: traits, cindex: cindex) }
    }

    func input(tap: ForyTarget?, content: String) throws {
        try run { try $0.input(tap: tap, content: content) }
    }

    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload {
        try run { try $0.swipe(to: to, from: from, distance: distance, dir: dir, traits: traits, cindex: cindex) }
    }

    func screenshot() throws -> Data {
        try run { try $0.screenshot() }
    }
}

private enum FlowRegex {
    static let template = try! NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
    static let outputName = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_-]*$"#)
    static let searchSeparator = try! NSRegularExpression(pattern: #"[\s\-_:\/()\[\]{}.,'"]"#)
}
