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
        let bootstrapVars = try resolveVars(rawVars: flow.vars, inheritedVars: options.externalVars)
        let flowApp = try flow.app.map { try resolveTemplates($0, vars: bootstrapVars) } as? String
        let needNSLog = try flow.needNSLog.map { try resolveTemplates($0, vars: bootstrapVars) }
        let interruptMonitor = InterruptMonitor()
        interruptMonitor.start()
        defer { interruptMonitor.stop() }

        var nsloggerServer: NSLoggerServer?
        var ownsNSLogLock = false
        defer {
            nsloggerServer?.stop()
            if ownsNSLogLock {
                NSLogService.releaseLock(paths: paths)
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
            try NSLogService.acquireForegroundOwnership(paths: paths, mode: "flow")
            let server = try NSLoggerServer(options: options, paths: paths)
            do {
                try server.start()
                try NSLogService.writeLock(paths: paths, server: server, mode: "flow")
                ownsNSLogLock = true
            } catch {
                server.stop()
                NSLogService.releaseLock(paths: paths)
                throw error
            }
            nsloggerServer = server
            emit("  → nslog: listening on port \(server.port)\n")
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
        runner.nsloggerServer = nsloggerServer
        if let server = nsloggerServer {
            runner.emit("Waiting for app to connect to NSLogger...\n")
            runner.emit(try waitForNSLoggerConnection(server: server, timeoutMilliseconds: IOSUseProtocol.flowNSLogConnectTimeoutMilliseconds, interruptMonitor: interruptMonitor))
        }
        _ = try runner.run(file: resolvedFile, inheritedVars: options.externalVars, stack: [])
        return runner.output
    }

    static func runForTesting(file: String, externalVars: [String: Any] = [:], paths: IOSUsePaths, driver: FlowDriver, udid: String? = nil) throws -> (stdout: String, outputs: [String: Any]) {
        var runner = FlowRunner(paths: paths, driver: driver, udid: udid, deviceType: nil, context: FlowRunContext())
        let outputs = try runner.run(file: file, inheritedVars: externalVars, stack: [])
        return (runner.output, outputs)
    }

    static func runForTesting(file: String, externalVars: [String: Any] = [:], paths: IOSUsePaths, driver: FlowDriver, udid: String? = nil, nsloggerServer: NSLoggerServer) throws -> (stdout: String, outputs: [String: Any]) {
        var runner = FlowRunner(paths: paths, driver: driver, udid: udid, deviceType: nil, context: FlowRunContext(), nsloggerServer: nsloggerServer)
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
            guard let nsloggerServer else {
                throw CLIParseError.invalidValue("nslog requires needNSLog in flow config")
            }
            let pattern = try requiredString(step["pattern"], field: "nslog.pattern")
            let flags = optionalString(step["flags"]) ?? ""
            let timeout = try optionalNumber(step["timeout"], field: "nslog.timeout") ?? 0
            let startedAt = Date()
            let matches = try waitForNSLogMatches(server: nsloggerServer, pattern: pattern, flags: flags, timeout: timeout, interruptMonitor: interruptMonitor)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let path = try saveLog(lines: matches, name: optionalString(step["name"]) ?? "nslog-\(flowTimestamp())")
            emit("  → nslog: \(matches.count) matched /\(pattern)/ in \(elapsedMs)ms → \(path)\n")
            if bool(step["clearAfterRead"]) {
                nsloggerServer.clear()
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
            _ = try driver.openURL(url: url)

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

private func waitForNSLoggerConnection(server: NSLoggerServer, timeoutMilliseconds: Int, interruptMonitor: InterruptMonitor? = nil) throws -> String {
    let startedAt = Date()
    let timeoutSeconds = Double(max(0, timeoutMilliseconds)) / 1000.0
    while Date().timeIntervalSince(startedAt) < timeoutSeconds {
        try interruptMonitor?.throwIfInterrupted()
        if server.activeClientCount > 0 {
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
