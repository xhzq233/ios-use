import Foundation
import IOSUseProtocol
import Yams

protocol FlowDriver {
    func activateApp(bundleId: String) throws
    func terminateApp(bundleId: String) throws
    func home() throws
    func openURL(url: String) throws -> ForySimpleStringPayload
    func dismissAlert(index: Int?) throws -> ForyAlertPayload
    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload
    func find(label: String, traits: String?, cindex: Int32?) throws -> ForyFindPayload
    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload
    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload
    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload
    func input(label: String, content: String, traits: String?, cindex: Int32?) throws
    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload
    func screenshot() throws -> Data
}

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
        let bootstrapVars = try resolveVars(rawVars: flow.vars, inheritedVars: options.externalVars)
        let flowApp = try flow.app.map { try resolveTemplates($0, vars: bootstrapVars) } as? String
        let needNSLog = try flow.needNSLog.map { try resolveTemplates($0, vars: bootstrapVars) }
        let interruptMonitor = InterruptMonitor()
        interruptMonitor.start()
        defer { interruptMonitor.stop() }

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
        try SessionService.prepareDriverSession(SessionOptions(udid: options.udid, verbose: options.verbose), paths: paths)
        let session = SessionService.read(paths: paths)
        let driver = RecoveringFlowDriver(paths: paths, verbose: options.verbose)
        defer { driver.close() }
        if let flowApp, !flowApp.isEmpty {
            do {
                try driver.terminateApp(bundleId: flowApp)
            } catch {
                if !IOSUseCLI.isAppNotRunningError(error) {
                    throw error
                }
            }
            try driver.activateApp(bundleId: flowApp)
        }
        var runner = FlowRunner(
            paths: paths,
            driver: driver,
            udid: options.udid ?? session?.udid,
            deviceType: session?.deviceType,
            context: context,
            inheritedFlowApp: flowApp,
            outputSink: outputSink,
            captureOutput: captureOutput,
            interruptMonitor: interruptMonitor
        )
        runner.output = bootstrapOutput
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
}

private struct FlowFile {
    var name: String
    var app: Any?
    var needNSLog: Any?
    var vars: [String: Any]
    var outputs: Any?
    var steps: [[String: Any]]
}

private final class FlowRunContext {
    var flowCache: [String: FlowFile] = [:]
    var compiledFiles = Set<String>()
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

        let flow = try cachedFlowFile(resolvedFile)
        var flowVars = try resolveVars(rawVars: flow.vars, inheritedVars: inheritedVars)
        let resolvedFlowApp = try flow.app.map { try resolveTemplates($0, vars: flowVars) } as? String
        let flowApp = resolvedFlowApp?.isEmpty == false ? resolvedFlowApp : inheritedFlowApp
        let needNSLog = try flow.needNSLog.map { try resolveTemplates($0, vars: flowVars) }
        _ = try nsloggerOptions(needNSLog)
        let visibleStepCount = flow.steps.reduce(0) { count, step in
            count + (isInvisibleFlowStep(step) ? 0 : 1)
        }
        emit("Running flow: \(flow.name) (\(visibleStepCount) steps)\n")

        let nextStack = stack + [resolvedFile]
        var visibleStepIndex = 0
        for rawStep in flow.steps {
            try throwIfInterrupted()
            let resolved = try resolveTemplates(rawStep, vars: flowVars) as? [String: Any] ?? rawStep
            let isVisible = !isInvisibleFlowStep(resolved)
            if isVisible {
                visibleStepIndex += 1
                emit("Step \(visibleStepIndex)/\(visibleStepCount): \(flowStepLabel(resolved))\n")
            }
            do {
                if try runStep(resolved, rawStep: rawStep, baseFile: resolvedFile, flowApp: flowApp, flowVars: &flowVars, stack: nextStack) {
                    break
                }
            } catch {
                if isVisible {
                    throw CLIParseError.invalidValue("Step \(visibleStepIndex) [action: \(resolved["action"] as? String ?? "")] failed: \(error)")
                }
                throw error
            }
        }

        emit("Flow completed: \(visibleStepIndex) steps executed\n")
        return try collectFlowOutputs(flow.outputs, vars: flowVars)
    }

    private mutating func runStep(_ step: [String: Any], rawStep: [String: Any], baseFile: String, flowApp: String?, flowVars: inout [String: Any], stack: [String]) throws -> Bool {
        try throwIfInterrupted()
        let action = step["action"] as? String ?? ""
        if !["find", "dom", "runFlow", "swipe"].contains(action), hasOutputs(rawStep["outputs"]) {
            throw CLIParseError.invalidValue("\(action) does not support outputs")
        }
        switch action {
        case "waitFor":
            let label = try requiredString(step["label"], field: "waitFor.label")
            _ = try driver.waitFor(label: label, timeout: optionalNumber(step["timeout"], field: "waitFor.timeout"), traits: optionalString(step["traits"]), cindex: optionalInt32(step["cindex"], field: "waitFor.cindex"))

        case "find":
            let label = try requiredString(step["label"], field: "find.label")
            let payload = try driver.find(label: label, traits: optionalString(step["traits"]), cindex: optionalInt32(step["cindex"], field: "find.cindex"))
            if printEnabled(step["print"]) {
                emit(DriverOutput.formatFind(label: label, payload: payload))
            }
            try bindSingleOutput(rawStep["outputs"], action: action, vars: &flowVars, value: findOutput(payload))

        case "dom":
            let payload = try driver.dom(raw: bool(step["raw"]), fresh: bool(step["fresh"]))
            let candidates = try optionalStringList(step["candidates"], field: "dom.candidates")
            let needsDerived = hasOutputs(rawStep["outputs"]) || (bool(step["save"]) && !bool(step["raw"]))
            let derived = needsDerived ? domOutput(payload, candidates: candidates) : [:]
            if bool(step["save"]) {
                try saveDom(payload, derived: derived, raw: bool(step["raw"]), name: (step["name"] as? String) ?? "dom-\(flowTimestamp())")
            }
            if printEnabled(step["print"]) {
                emit(DriverOutput.formatDom(payload))
            }
            try bindSingleOutput(rawStep["outputs"], action: action, vars: &flowVars, value: derived)

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
            let requested = try outputNames(rawStep["outputs"], fieldName: "runFlow outputs", allowMultiple: true)
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
            let childOutputs = try child.run(file: childFile, inheritedVars: flowVars.merging(childVars) { _, new in new }, stack: stack)
            if outputSink == nil {
                output += child.output
            }
            for name in requested {
                flowVars[name] = childOutputs[name] ?? NSNull()
            }

        case "tap":
            emit("Tap\n")
            let tapTarget = try requiredTarget(step["label"], field: "tap.label")
            let offset = try offsetPoint(step["offset"] as? [String: Any])
            if tapTarget.point != nil, offset != nil {
                throw CLIParseError.invalidValue("offset requires element label, not absolute point")
            }
            let traits = optionalString(step["traits"])
            let cindex = try optionalInt32(step["cindex"], field: "tap.cindex")
            try validateLookupOptions(target: tapTarget, traits: traits, cindex: cindex, field: "tap.label")
            let ratio = try ratioPoint(step["offset"] as? [String: Any], hasAbsoluteOffset: offset != nil)
            _ = try driver.tap(target: tapTarget, traits: traits, cindex: cindex, offset: offset, ratio: ratio)

        case "longpress":
            let pressTarget = try requiredTarget(step["label"], field: "longpress.label")
            let traits = optionalString(step["traits"])
            let cindex = try optionalInt32(step["cindex"], field: "longpress.cindex")
            try validateLookupOptions(target: pressTarget, traits: traits, cindex: cindex, field: "longpress.label")
            _ = try driver.longPress(
                target: pressTarget,
                durationMs: optionalInt(step["duration"], field: "longpress.duration"),
                traits: traits,
                cindex: cindex
            )

        case "input":
            let label = try requiredString(step["label"], field: "input.label")
            let content = try requiredString(step["content"], field: "input.content")
            try driver.input(label: label, content: content, traits: optionalString(step["traits"]), cindex: optionalInt32(step["cindex"], field: "input.cindex"))
            emit("Input \"\(content)\" into \"\(label)\"\n")

        case "screenshot":
            let name = step["name"] as? String ?? "flow-step-\(flowTimestamp())"
            try saveScreenshot(name: name)

        case "oslog":
            if bool(step["clear"]) {
                if let udid {
                    emit(OSLogService.clear(udid: udid))
                } else {
                    emit(OSLogService.clear())
                }
            } else {
                guard let udid else { throw CLIParseError.invalidValue("oslog requires --udid") }
                emit(try OSLogService.fetch(
                    udid: udid,
                    pattern: optionalString(step["pattern"]),
                    flags: optionalString(step["flags"]),
                    bundleId: optionalString(step["bundleId"]),
                    timeout: try optionalNumber(step["timeout"], field: "oslog.timeout"),
                    name: optionalString(step["name"]),
                    paths: paths,
                    deviceTypeHint: deviceType
                ))
            }

        case "nslog":
            guard nslogCapture != nil || nsloggerServer != nil else {
                throw CLIParseError.invalidValue("nslog requires needNSLog in flow config")
            }
            let pattern = try requiredString(step["pattern"], field: "nslog.pattern")
            let flags = optionalString(step["flags"]) ?? ""
            let timeout = try optionalNumber(step["timeout"], field: "nslog.timeout") ?? 0
            let startedAt = Date()
            let matches: [String]
            if let nslogCapture {
                let output = try NSLogService.readCapture(capture: nslogCapture, pattern: pattern, flags: flags, timeout: timeout, clearAfterRead: bool(step["clearAfterRead"]), last: nil, interruptMonitor: interruptMonitor)
                matches = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
            } else if let nsloggerServer {
                matches = try waitForNSLogMatches(server: nsloggerServer, pattern: pattern, flags: flags, timeout: timeout, interruptMonitor: interruptMonitor)
                if bool(step["clearAfterRead"]) {
                    nsloggerServer.clear()
                }
            } else {
                matches = []
            }
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let path = try saveLog(lines: matches, name: optionalString(step["name"]) ?? "nslog-\(flowTimestamp())")
            emit("  → nslog: \(matches.count) matched /\(pattern)/ in \(elapsedMs)ms → \(path)\n")
            if bool(step["clearAfterRead"]) {
                emit("  → nslog: buffer cleared\n")
            }

        case "swipe":
            let dir = optionalString(step["dir"])
            if let dir, dir != "forth", dir != "back" {
                throw CLIParseError.invalidValue("swipe.dir must be \"forth\" or \"back\"")
            }
            let toTarget = try target(step["to"])
            let fromTarget = try target(step["from"])
            let traits = optionalString(step["traits"])
            let cindex = try optionalInt32(step["cindex"], field: "swipe.cindex")
            try validateLookupOptions(target: toTarget, traits: traits, cindex: cindex, field: "swipe.to")
            let payload = try driver.swipe(
                to: toTarget,
                from: fromTarget,
                distance: optionalNumber(step["distance"], field: "swipe.distance"),
                dir: dir,
                traits: traits,
                cindex: cindex
            )
            try bindSingleOutput(rawStep["outputs"], action: action, vars: &flowVars, value: swipeOutput(payload))

        case "activateApp":
            guard let bundleId = optionalString(step["bundleId"]) ?? flowApp, !bundleId.isEmpty else {
                throw CLIParseError.invalidValue("activateApp requires bundleId")
            }
            try driver.activateApp(bundleId: bundleId)

        case "terminateApp":
            guard let bundleId = optionalString(step["bundleId"]) ?? flowApp, !bundleId.isEmpty else {
                throw CLIParseError.invalidValue("terminateApp requires bundleId")
            }
            do {
                try driver.terminateApp(bundleId: bundleId)
            } catch {
                if !IOSUseCLI.isAppNotRunningError(error) {
                    throw error
                }
            }

        case "home":
            try driver.home()

        case "openURL":
            guard let url = optionalString(step["url"]) ?? optionalString(step["content"]), !url.isEmpty else {
                throw CLIParseError.invalidValue("openURL requires url")
            }
            let validatedURL = try OpenURLService.validatedURL(url)
            if try !OpenURLService.openHostSideIfAvailable(url: validatedURL, udid: udid, deviceType: deviceType, paths: paths) {
                _ = try driver.openURL(url: validatedURL)
            }

        case "dismissAlert":
            _ = try driver.dismissAlert(index: optionalInt(step["index"], field: "dismissAlert.index"))

        default:
            throw CLIParseError.invalidValue("unsupported flow action: \(action)")
        }
        return false
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

    private func bindSingleOutput(_ raw: Any?, action: String, vars: inout [String: Any], value: Any?) throws {
        let names = try outputNames(raw, fieldName: "\(action) outputs", allowMultiple: false)
        guard let name = names.first else { return }
        vars[name] = value ?? NSNull()
    }

    private func hasOutputs(_ raw: Any?) -> Bool {
        raw != nil && !(raw is NSNull)
    }

    private func saveScreenshot(name: String) throws {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "flow-step-\(flowTimestamp())", extension: "jpg")
        try driver.screenshot().write(to: URL(fileURLWithPath: path))
    }

    private func saveDom(_ payload: ForyDomPayload, derived: [String: Any], raw: Bool, name: String) throws {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        if raw {
            let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "dom-\(flowTimestamp())", extension: "txt")
            try (payload.raw + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: derived, options: [.prettyPrinted, .sortedKeys])
        let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "dom-\(flowTimestamp())", extension: "json")
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func resolveChildFile(_ file: String, baseFile: String) -> String {
        let base = URL(fileURLWithPath: baseFile).deletingLastPathComponent()
        return URL(fileURLWithPath: file, relativeTo: base).standardized.path
    }

    private func saveLog(lines: [String], name: String) throws -> String {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "nslog-\(flowTimestamp())", extension: "log")
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
        needNSLog: raw["needNSLog"],
        vars: raw["vars"] as? [String: Any] ?? [:],
        outputs: raw["outputs"],
        steps: steps
    )
}

private let flowStepGlobalKeys: Set<String> = ["action", "comment", "text"]

private let flowStepAllowedKeys: [String: Set<String>] = [
    "waitFor": ["label", "timeout", "traits", "cindex"],
    "find": ["label", "traits", "cindex", "outputs", "print"],
    "dom": ["raw", "fresh", "candidates", "outputs", "save", "print", "name"],
    "tap": ["label", "offset", "traits", "cindex"],
    "longpress": ["label", "duration", "traits", "cindex"],
    "input": ["label", "content", "traits", "cindex"],
    "swipe": ["dir", "from", "to", "distance", "traits", "cindex", "outputs"],
    "screenshot": ["name"],
    "activateApp": ["bundleId"],
    "terminateApp": ["bundleId"],
    "home": [],
    "openURL": ["url", "content"],
    "dismissAlert": ["index"],
    "oslog": ["clear", "pattern", "flags", "bundleId", "timeout", "name"],
    "nslog": ["pattern", "flags", "timeout", "clearAfterRead", "name"],
    "runFlow": ["file", "vars", "outputs"],
    "returnIf": ["value", "is"],
    "sleep": ["ms"],
]

private let flowOutputActions: Set<String> = ["find", "dom", "runFlow", "swipe"]

private func compileFlow(file: String, context: FlowRunContext, stack: [String]) throws {
    let resolvedFile = URL(fileURLWithPath: file).standardized.path
    if context.compiledFiles.contains(resolvedFile) {
        return
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

    let nextStack = stack + [resolvedFile]
    for (index, step) in flow.steps.enumerated() {
        try compileFlowStep(step, index: index + 1, baseFile: resolvedFile, context: context, stack: nextStack)
    }
    context.compiledFiles.insert(resolvedFile)
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

private func compileFlowStep(_ step: [String: Any], index: Int, baseFile: String, context: FlowRunContext, stack: [String]) throws {
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

    switch action {
    case "waitFor":
        try validateRequiredTarget(step["label"], field: "waitFor.label")
        try validateStaticNumber(step["timeout"], field: "waitFor.timeout")
        try validateStaticString(step["traits"], field: "waitFor.traits")
        try validateStaticInt32(step["cindex"], field: "waitFor.cindex")

    case "find":
        try validateRequiredTarget(step["label"], field: "find.label")
        try validateStaticString(step["traits"], field: "find.traits")
        try validateStaticInt32(step["cindex"], field: "find.cindex")
        _ = try outputNames(step["outputs"], fieldName: "find outputs", allowMultiple: false)
        try validateStaticBool(step["print"], field: "find.print")

    case "dom":
        try validateStaticBool(step["raw"], field: "dom.raw")
        try validateStaticBool(step["fresh"], field: "dom.fresh")
        try validateStaticStringList(step["candidates"], field: "dom.candidates")
        _ = try outputNames(step["outputs"], fieldName: "dom outputs", allowMultiple: false)
        try validateStaticBool(step["save"], field: "dom.save")
        try validateStaticBool(step["print"], field: "dom.print")
        try validateStaticString(step["name"], field: "dom.name")

    case "tap":
        try validateRequiredTarget(step["label"], field: "tap.label")
        try validateTapOffsetForCompile(step["offset"])
        try validateStaticString(step["traits"], field: "tap.traits")
        try validateStaticInt32(step["cindex"], field: "tap.cindex")

    case "longpress":
        try validateRequiredTarget(step["label"], field: "longpress.label")
        try validateStaticInt(step["duration"], field: "longpress.duration")
        try validateStaticString(step["traits"], field: "longpress.traits")
        try validateStaticInt32(step["cindex"], field: "longpress.cindex")

    case "input":
        try validateRequiredStaticString(step["label"], field: "input.label")
        try validateRequiredStaticString(step["content"], field: "input.content")
        try validateStaticString(step["traits"], field: "input.traits")
        try validateStaticInt32(step["cindex"], field: "input.cindex")

    case "swipe":
        try validateStaticSwipeDir(step["dir"])
        try validateOptionalTarget(step["to"], field: "swipe.to")
        try validateOptionalTarget(step["from"], field: "swipe.from")
        try validateStaticNumber(step["distance"], field: "swipe.distance")
        try validateStaticString(step["traits"], field: "swipe.traits")
        try validateStaticInt32(step["cindex"], field: "swipe.cindex")
        _ = try outputNames(step["outputs"], fieldName: "swipe outputs", allowMultiple: false)

    case "screenshot":
        try validateStaticString(step["name"], field: "screenshot.name")

    case "activateApp":
        try validateStaticString(step["bundleId"], field: "activateApp.bundleId")

    case "terminateApp":
        try validateStaticString(step["bundleId"], field: "terminateApp.bundleId")

    case "home":
        break

    case "openURL":
        guard !isNull(step["url"]) || !isNull(step["content"]) else {
            throw CLIParseError.invalidValue("openURL requires url")
        }
        let url = try validateStaticString(step["url"], field: "openURL.url")
        let content = try validateStaticString(step["content"], field: "openURL.content")
        if let value = url ?? content, !containsTemplate(value) {
            _ = try OpenURLService.validatedURL(value)
        }

    case "dismissAlert":
        try validateStaticInt(step["index"], field: "dismissAlert.index")

    case "oslog":
        try validateStaticBool(step["clear"], field: "oslog.clear")
        try validateStaticString(step["pattern"], field: "oslog.pattern")
        try validateStaticString(step["flags"], field: "oslog.flags")
        try validateStaticString(step["bundleId"], field: "oslog.bundleId")
        try validateStaticNumber(step["timeout"], field: "oslog.timeout")
        try validateStaticString(step["name"], field: "oslog.name")

    case "nslog":
        try validateRequiredStaticString(step["pattern"], field: "nslog.pattern")
        try validateStaticString(step["flags"], field: "nslog.flags")
        try validateStaticNumber(step["timeout"], field: "nslog.timeout")
        try validateStaticBool(step["clearAfterRead"], field: "nslog.clearAfterRead")
        try validateStaticString(step["name"], field: "nslog.name")

    case "runFlow":
        let childFileValue = try requiredStaticString(step["file"], field: "runFlow.file")
        guard let vars = step["vars"], !isNull(vars) else {
            try validateRunFlowOutputs(step["outputs"], childFileValue: childFileValue, baseFile: baseFile, context: context, stack: stack)
            return
        }
        guard vars is [String: Any] || containsTemplate(vars) else {
            throw CLIParseError.invalidValue("runFlow.vars must be an object")
        }
        try validateRunFlowOutputs(step["outputs"], childFileValue: childFileValue, baseFile: baseFile, context: context, stack: stack)

    case "returnIf":
        guard step.keys.contains("value") else {
            throw CLIParseError.invalidValue("returnIf requires \"value\"")
        }
        if !containsTemplate(step["is"]), !isAllowedReturnMatcher(step["is"]) {
            throw CLIParseError.invalidValue("returnIf requires \"is\" to be true, false, or null")
        }

    case "sleep":
        if let ms = try validateStaticInt(step["ms"], field: "sleep.ms") {
            let maxSleepMilliseconds = Int(UInt32.max / UInt32(IOSUseProtocol.microsecondsPerMillisecond))
            guard ms <= maxSleepMilliseconds else {
                throw CLIParseError.invalidValue("sleep.ms is too large")
            }
        }

    default:
        break
    }
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

private func findOutput(_ payload: ForyFindPayload) -> [String: Any] {
    let matches = payload.matches.map(matchObject)
    return [
        "matches": matches,
        "firstMatch": matches.first ?? NSNull(),
    ]
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
        "elements": payload.elements.map(domElementObject),
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

private func matchObject(_ match: ForyFindMatch) -> [String: Any] {
    var out: [String: Any] = [
        "type": DriverOutput.elementTypeName(match.elemType),
        "label": match.label,
        "traits": match.traits,
    ]
    if !match.value.isEmpty {
        out["value"] = match.value
    }
    if let rect = match.rect {
        out["rect"] = [rect.x, rect.y, rect.w, rect.h]
    }
    if !match.ancestors.isEmpty {
        out["ancestors"] = match.ancestors
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
private func validateRequiredStaticString(_ value: Any?, field: String) throws -> String {
    try requiredStaticString(value, field: field)
}

@discardableResult
private func validateStaticString(_ value: Any?, field: String) throws -> String? {
    guard !isNull(value) else { return nil }
    guard let string = value as? String else {
        throw CLIParseError.invalidValue("\(field) must be a string")
    }
    return string
}

private func validateStaticStringList(_ value: Any?, field: String) throws {
    guard !isNull(value) else { return }
    guard let list = value as? [Any] else {
        throw CLIParseError.invalidValue("\(field) must be a string array")
    }
    for item in list {
        guard let string = item as? String, !string.isEmpty else {
            throw CLIParseError.invalidValue("\(field) must contain only non-empty strings")
        }
    }
}

private func validateStaticBool(_ value: Any?, field: String) throws {
    guard !isNull(value), !containsTemplate(value) else { return }
    guard value is Bool else {
        throw CLIParseError.invalidValue("\(field) must be a boolean")
    }
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

private func validateStaticInt32(_ value: Any?, field: String) throws {
    guard !isNull(value), !containsTemplate(value) else { return }
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
    guard parsed >= Int(Int32.min), parsed <= Int(Int32.max) else {
        throw CLIParseError.invalidValue("\(field) is out of Int32 range")
    }
}

private func validateStaticNumber(_ value: Any?, field: String) throws {
    guard !isNull(value), !containsTemplate(value) else { return }
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
    guard parsed >= 0 else {
        throw CLIParseError.invalidValue("\(field) must be non-negative")
    }
}

private func validateRequiredTarget(_ value: Any?, field: String) throws {
    try validateOptionalTarget(value, field: field)
    if isNull(value) {
        throw CLIParseError.invalidValue("\(field) must be a non-empty string or [x, y] point")
    }
    if let string = value as? String, string.isEmpty {
        throw CLIParseError.invalidValue("\(field) must be a non-empty string or [x, y] point")
    }
}

private func validateOptionalTarget(_ value: Any?, field: String) throws {
    guard !isNull(value) else { return }
    if containsTemplate(value) { return }
    _ = try target(value)
}

private func validateStaticSwipeDir(_ value: Any?) throws {
    guard let dir = try validateStaticString(value, field: "swipe.dir"), !containsTemplate(dir) else { return }
    if dir != "forth", dir != "back" {
        throw CLIParseError.invalidValue("swipe.dir must be \"forth\" or \"back\"")
    }
}

private func validateTapOffsetForCompile(_ value: Any?) throws {
    guard !isNull(value) else { return }
    guard let offset = value as? [String: Any] else {
        throw CLIParseError.invalidValue("tap offset must be a dict with x/y/xRatio/yRatio keys")
    }
    let allowed = Set(["x", "y", "xRatio", "yRatio"])
    for key in offset.keys where !allowed.contains(key) {
        throw CLIParseError.invalidValue("tap offset must be a dict with x/y/xRatio/yRatio keys")
    }
    if offset["x"] != nil, offset["xRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both x and xRatio")
    }
    if offset["y"] != nil, offset["yRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both y and yRatio")
    }
    for key in ["x", "y"] {
        if !isNull(offset[key]), !containsTemplate(offset[key]) {
            try validateOffsetNumber(offset[key], message: "tap offset x and y must be finite numbers")
        }
    }
    for key in ["xRatio", "yRatio"] {
        if !isNull(offset[key]), !containsTemplate(offset[key]) {
            try validateOffsetNumber(offset[key], message: "tap offset xRatio and yRatio must be finite numbers")
        }
    }
}

private func validateOffsetNumber(_ value: Any?, message: String) throws {
    if let double = value as? Double, double.isFinite { return }
    if value is Int || value is Int32 { return }
    throw CLIParseError.invalidValue(message)
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

private func printEnabled(_ value: Any?) -> Bool {
    if isNull(value) { return true }
    return bool(value)
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

private func optionalInt32(_ value: Any?, field: String) throws -> Int32? {
    guard !isNull(value) else { return nil }
    guard let parsed = intValue(value) else {
        throw CLIParseError.invalidValue("\(field) must be an integer")
    }
    guard parsed >= Int(Int32.min), parsed <= Int(Int32.max) else {
        throw CLIParseError.invalidValue("\(field) is out of Int32 range")
    }
    return Int32(parsed)
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

private func optionalNumber(_ value: Any?, field: String) throws -> Double? {
    guard !isNull(value) else { return nil }
    guard let parsed = number(value) else {
        throw CLIParseError.invalidValue("\(field) must be a finite number")
    }
    guard parsed >= 0 else {
        throw CLIParseError.invalidValue("\(field) must be non-negative")
    }
    return parsed
}

private func optionalPositiveNumber(_ value: Any?, field: String) throws -> Double? {
    guard let parsed = try optionalNumber(value, field: field) else { return nil }
    guard parsed > 0 else {
        throw CLIParseError.invalidValue("\(field) must be greater than 0")
    }
    return parsed
}

private func requiredTarget(_ value: Any?, field: String) throws -> ForyTarget {
    let target = try target(value)
    if target.label.isEmpty, target.point == nil {
        throw CLIParseError.invalidValue("\(field) must be a non-empty string or [x, y] point")
    }
    return target
}

private func validateLookupOptions(target: ForyTarget, traits: String?, cindex: Int32?, field: String) throws {
    guard traits != nil || cindex != nil else { return }
    if target.label.isEmpty, target.point == nil {
        throw CLIParseError.invalidValue("\(field) requires a label target when using traits or cindex")
    }
    if target.point != nil {
        throw CLIParseError.invalidValue("\(field) point target does not support traits or cindex")
    }
}

private func target(_ value: Any?) throws -> ForyTarget {
    guard let value, !isNull(value) else { return ForyTarget() }
    if let string = value as? String {
        guard !string.isEmpty else { return ForyTarget() }
        if FlowRegex.pointPair.firstMatch(in: string, range: NSRange(string.startIndex..<string.endIndex, in: string)) != nil {
            let point = try pointPair(string)
            return ForyTarget(label: "", point: point)
        }
        if looksLikeInvalidPointPair(string) {
            throw CLIParseError.invalidValue("Invalid point: \"\(string)\"")
        }
        return ForyTarget(label: string, point: nil)
    }
    if let list = value as? [Any] {
        guard list.count == 2,
              let x = number(list[0]),
              let y = number(list[1]) else {
            throw CLIParseError.invalidValue("Invalid point target: \(value)")
        }
        let point = ForyPoint(x: x, y: y)
        return ForyTarget(label: "", point: point)
    }
    throw CLIParseError.invalidValue("Invalid target: \(value)")
}

private func pointPair(_ value: String) throws -> ForyPoint {
    let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    guard parts.count == 2,
          let x = Double(parts[0]),
          let y = Double(parts[1]),
          x.isFinite,
          y.isFinite else {
        throw CLIParseError.invalidValue("Invalid point: \"\(value)\"")
    }
    return ForyPoint(x: x, y: y)
}

private func looksLikeInvalidPointPair(_ value: String) -> Bool {
    let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    guard parts.count == 2 else { return false }
    return parts.contains { part in
        part == "inf" || part == "+inf" || part == "-inf" || part == "infinity" || part == "nan" ||
            part.range(of: #"^[+-]?(?:\d|\.\d)"#, options: .regularExpression) != nil
    }
}

private func offsetPoint(_ offset: [String: Any]?) throws -> ForyPoint? {
    guard let offset else { return nil }
    if offset["x"] != nil, offset["xRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both x and xRatio")
    }
    if offset["y"] != nil, offset["yRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both y and yRatio")
    }
    let hasX = offset["x"] != nil
    let hasY = offset["y"] != nil
    if hasX || hasY {
        guard let x = hasX ? number(offset["x"]) : 0,
              let y = hasY ? number(offset["y"]) : 0 else {
            throw CLIParseError.invalidValue("tap offset x and y must be finite numbers")
        }
        return ForyPoint(x: x, y: y)
    }
    return nil
}

private func ratioPoint(_ offset: [String: Any]?, hasAbsoluteOffset: Bool) throws -> ForyPoint {
    guard let offset, !hasAbsoluteOffset else { return ForyPoint(x: 0.5, y: 0.5) }
    if offset["x"] != nil, offset["xRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both x and xRatio")
    }
    if offset["y"] != nil, offset["yRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both y and yRatio")
    }
    let hasXRatio = offset["xRatio"] != nil
    let hasYRatio = offset["yRatio"] != nil
    if hasXRatio || hasYRatio {
        guard let x = hasXRatio ? number(offset["xRatio"]) : 0.5,
              let y = hasYRatio ? number(offset["yRatio"]) : 0.5 else {
            throw CLIParseError.invalidValue("tap offset xRatio and yRatio must be finite numbers")
        }
        return ForyPoint(x: x, y: y)
    }
    return ForyPoint(x: 0.5, y: 0.5)
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
    private let paths: IOSUsePaths
    private let verbose: Bool
    private var driver: DriverClient

    init(paths: IOSUsePaths, verbose: Bool) {
        self.paths = paths
        self.verbose = verbose
        self.driver = DriverClient(session: SessionService.read(paths: paths))
    }

    func close() {
        driver.close()
    }

    private func run<T>(_ body: (DriverClient) throws -> T) throws -> T {
        do {
            return try body(driver)
        } catch {
            guard (error as? DriverClientError)?.isRecoverableConnectFailure == true else {
                throw error
            }
            driver.close()
            try SessionService.launchPreparedDriverSession(paths: paths, verbose: verbose)
            driver = DriverClient(session: SessionService.read(paths: paths))
            return try body(driver)
        }
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

    func openURL(url: String) throws -> ForySimpleStringPayload {
        try run { try $0.openURL(url: url) }
    }

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        try run { try $0.dismissAlert(index: index) }
    }

    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload {
        try run { try $0.waitFor(label: label, timeout: timeout, traits: traits, cindex: cindex) }
    }

    func find(label: String, traits: String?, cindex: Int32?) throws -> ForyFindPayload {
        try run { try $0.find(label: label, traits: traits, cindex: cindex) }
    }

    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload {
        try run { try $0.dom(raw: raw, fresh: fresh) }
    }

    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload {
        try run { try $0.tap(target: target, traits: traits, cindex: cindex, offset: offset, ratio: ratio) }
    }

    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload {
        try run { try $0.longPress(target: target, durationMs: durationMs, traits: traits, cindex: cindex) }
    }

    func input(label: String, content: String, traits: String?, cindex: Int32?) throws {
        try run { try $0.input(label: label, content: content, traits: traits, cindex: cindex) }
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
    static let pointPair = try! NSRegularExpression(pattern: #"^\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*,\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*$"#)
}
