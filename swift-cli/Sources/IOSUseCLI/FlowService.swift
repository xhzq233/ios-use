import Foundation
import IOSUseProtocol
import Yams

protocol FlowDriver {
    func activateApp(bundleId: String) throws
    func terminateApp(bundleId: String) throws
    func home() throws
    func openURL(url: String) throws -> ForySimpleStringPayload
    func dismissAlert(index: Int?) throws -> ForyAlertPayload
    func waitFor(label: String, timeout: Double?, traits: String?) throws -> ForyWaitForPayload
    func find(label: String, traits: String?) throws -> ForyFindPayload
    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload
    func tap(target: ForyTarget, traits: String?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload
    func input(label: String, content: String, traits: String?) throws
    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?) throws -> ForySwipePayload
    func screenshot() throws -> Data
}

extension DriverClient: FlowDriver {}

public enum FlowService {
    public static func run(file: String, options: FlowOptions, paths: IOSUsePaths) throws -> String {
        var runner = FlowRunner(paths: paths, driver: DriverClient(), udid: options.udid)
        _ = try runner.run(file: file, inheritedVars: options.externalVars, stack: [])
        return runner.output
    }

    static func runForTesting(file: String, externalVars: [String: Any] = [:], paths: IOSUsePaths, driver: FlowDriver, udid: String? = nil) throws -> (stdout: String, outputs: [String: Any]) {
        var runner = FlowRunner(paths: paths, driver: driver, udid: udid)
        let outputs = try runner.run(file: file, inheritedVars: externalVars, stack: [])
        return (runner.output, outputs)
    }
}

private struct FlowFile {
    var name: String
    var app: Any?
    var vars: [String: Any]
    var outputs: Any?
    var steps: [[String: Any]]
}

private struct FlowRunner {
    let paths: IOSUsePaths
    let driver: FlowDriver
    let udid: String?
    var output = ""

    mutating func run(file: String, inheritedVars: [String: Any], stack: [String]) throws -> [String: Any] {
        let resolvedFile = URL(fileURLWithPath: file).standardized.path
        guard FileManager.default.fileExists(atPath: resolvedFile) else {
            throw CLIParseError.invalidValue("Flow file not found: \(file)")
        }
        if stack.contains(resolvedFile) {
            throw CLIParseError.invalidValue("runFlow cycle detected: \((stack + [resolvedFile]).joined(separator: " -> "))")
        }

        let flow = try loadFlowFile(resolvedFile)
        var flowVars = try resolveVars(rawVars: flow.vars, inheritedVars: inheritedVars)
        let flowApp = try flow.app.map { try resolveTemplates($0, vars: flowVars) } as? String

        output += "Running flow: \(flow.name)\n"
        if let flowApp {
            try driver.activateApp(bundleId: flowApp)
        }

        let nextStack = stack + [resolvedFile]
        for rawStep in flow.steps {
            let resolved = try resolveTemplates(rawStep, vars: flowVars) as? [String: Any] ?? rawStep
            if try runStep(resolved, rawStep: rawStep, baseFile: resolvedFile, flowApp: flowApp, flowVars: &flowVars, stack: nextStack) {
                break
            }
        }

        return try collectFlowOutputs(flow.outputs, vars: flowVars)
    }

    private mutating func runStep(_ step: [String: Any], rawStep: [String: Any], baseFile: String, flowApp: String?, flowVars: inout [String: Any], stack: [String]) throws -> Bool {
        let action = step["action"] as? String ?? ""
        switch action {
        case "waitFor":
            let label = try requiredString(step["label"], field: "waitFor.label")
            _ = try driver.waitFor(label: label, timeout: number(step["timeout"]), traits: optionalString(step["traits"]))

        case "find":
            let label = try requiredString(step["label"], field: "find.label")
            let payload = try driver.find(label: label, traits: optionalString(step["traits"]))
            try bindSingleOutput(rawStep["outputs"], action: action, vars: &flowVars, value: findOutput(payload))

        case "dom":
            let payload = try driver.dom(raw: bool(step["raw"]), fresh: bool(step["fresh"]))
            let candidates = (step["candidates"] as? [Any] ?? []).map { String(describing: $0) }
            let derived = domOutput(payload, candidates: candidates)
            if bool(step["save"]) {
                try saveDom(payload, derived: derived, raw: bool(step["raw"]), name: (step["name"] as? String) ?? "dom")
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
                output += "returnIf matched is=\(formatReturnMatcher(step["is"])), returning current flow\n"
                return true
            }

        case "sleep":
            let ms = Int(number(step["ms"]) ?? 1000)
            usleep(useconds_t(max(0, ms) * 1000))

        case "runFlow":
            let childFileValue = try requiredString(step["file"], field: "runFlow.file")
            let childFile = resolveChildFile(childFileValue, baseFile: baseFile)
            let childFlow = try loadFlowFile(childFile)
            let requested = try outputNames(rawStep["outputs"], fieldName: "runFlow outputs", allowMultiple: true)
            let declared = try outputNames(childFlow.outputs, fieldName: "flow outputs", allowMultiple: true)
            for name in requested where !declared.contains(name) {
                throw CLIParseError.invalidValue("runFlow requested undeclared output \"\(name)\" from \(childFile)")
            }
            let childVarsRaw = step["vars"] as? [String: Any] ?? [:]
            let childVars = try resolveTemplates(childVarsRaw, vars: flowVars) as? [String: Any] ?? childVarsRaw
            var child = FlowRunner(paths: paths, driver: driver, udid: udid)
            let childOutputs = try child.run(file: childFile, inheritedVars: flowVars.merging(childVars) { _, new in new }, stack: stack)
            output += child.output
            for name in requested {
                flowVars[name] = childOutputs[name] ?? NSNull()
            }

        case "tap":
            output += "Tap\n"
            let label = try requiredString(step["label"], field: "tap.label")
            let offset = try offsetPoint(step["offset"] as? [String: Any])
            let tapTarget = try target(label)
            if tapTarget.point != nil, offset != nil {
                throw CLIParseError.invalidValue("offset requires element label, not absolute point")
            }
            let ratio = try ratioPoint(step["offset"] as? [String: Any], hasAbsoluteOffset: offset != nil)
            _ = try driver.tap(target: tapTarget, traits: optionalString(step["traits"]), offset: offset, ratio: ratio)

        case "input":
            let label = try requiredString(step["label"], field: "input.label")
            let content = try requiredString(step["content"], field: "input.content")
            try driver.input(label: label, content: content, traits: optionalString(step["traits"]))
            output += "Input \"\(content)\" into \"\(label)\"\n"

        case "screenshot":
            let name = step["name"] as? String ?? "screenshot"
            try saveScreenshot(name: name)

        case "oslog":
            if bool(step["clear"]) {
                output += OSLogService.clear()
            } else {
                guard let udid else { throw CLIParseError.invalidValue("oslog requires --udid") }
                output += try OSLogService.fetchSimulator(
                    udid: udid,
                    pattern: optionalString(step["pattern"]),
                    flags: optionalString(step["flags"]),
                    bundleId: optionalString(step["bundleId"]),
                    timeout: number(step["timeout"]),
                    name: optionalString(step["name"]),
                    paths: paths
                )
            }

        case "swipe":
            _ = try driver.swipe(
                to: try target(optionalString(step["to"])),
                from: try target(optionalString(step["from"])),
                distance: number(step["distance"]),
                dir: optionalString(step["dir"]),
                traits: optionalString(step["traits"])
            )

        case "activateApp":
            guard let bundleId = optionalString(step["bundleId"]) ?? flowApp, !bundleId.isEmpty else {
                throw CLIParseError.invalidValue("activateApp requires bundleId")
            }
            try driver.activateApp(bundleId: bundleId)

        case "terminateApp":
            guard let bundleId = optionalString(step["bundleId"]) ?? flowApp, !bundleId.isEmpty else {
                throw CLIParseError.invalidValue("terminateApp requires bundleId")
            }
            try driver.terminateApp(bundleId: bundleId)

        case "home":
            try driver.home()

        case "openURL":
            guard let url = optionalString(step["url"]) ?? optionalString(step["content"]), !url.isEmpty else {
                throw CLIParseError.invalidValue("openURL requires url")
            }
            _ = try driver.openURL(url: url)

        case "dismissAlert":
            _ = try driver.dismissAlert(index: intValue(step["index"]))

        default:
            throw CLIParseError.invalidValue("unsupported flow action: \(action)")
        }
        return false
    }

    private func bindSingleOutput(_ raw: Any?, action: String, vars: inout [String: Any], value: Any?) throws {
        let names = try outputNames(raw, fieldName: "\(action) outputs", allowMultiple: false)
        guard let name = names.first else { return }
        vars[name] = value ?? NSNull()
    }

    private func saveScreenshot(name: String) throws {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        try driver.screenshot().write(to: URL(fileURLWithPath: "\(paths.artifacts)/\(name).jpg"))
    }

    private func saveDom(_ payload: ForyDomPayload, derived: [String: Any], raw: Bool, name: String) throws {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        if raw {
            try (payload.raw + "\n").write(toFile: "\(paths.artifacts)/\(name).txt", atomically: true, encoding: .utf8)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: derived, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "\(paths.artifacts)/\(name).json"))
    }

    private func resolveChildFile(_ file: String, baseFile: String) -> String {
        let base = URL(fileURLWithPath: baseFile).deletingLastPathComponent()
        return URL(fileURLWithPath: file, relativeTo: base).standardized.path
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
        vars: raw["vars"] as? [String: Any] ?? [:],
        outputs: raw["outputs"],
        steps: steps
    )
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
    let regex = try NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
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

    var scope = vars
    scope["vars"] = vars
    var current: Any? = scope
    for part in parts {
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
    let valid = try NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_-]*$"#)
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

private func domOutput(_ payload: ForyDomPayload, candidates: [String]) -> [String: Any] {
    var matches: [[String: Any]] = []
    var matchedIndexes = Set<Int>()
    for candidate in candidates.map(normalizeSearchText).filter({ !$0.isEmpty }) {
        for (idx, element) in payload.elements.enumerated() where !matchedIndexes.contains(idx) {
            let texts = [element.label, element.value].map(normalizeSearchText)
            if texts.contains(where: { $0.contains(candidate) }) {
                matchedIndexes.insert(idx)
                matches.append(domElementObject(element))
            }
        }
    }
    return [
        "dom": domObject(payload),
        "matches": matches,
        "firstMatch": matches.first ?? NSNull(),
    ]
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
        "traits": element.traits,
        "childCount": element.childCount,
        "label": element.label,
        "value": element.value,
        "rect": rectObject(element.rect) as Any,
    ]
}

private func matchObject(_ match: ForyFindMatch) -> [String: Any] {
    [
        "type": match.elemType,
        "label": match.label,
        "value": match.value,
        "traits": match.traits,
        "ancestors": match.ancestors,
        "rect": rectObject(match.rect) as Any,
    ]
}

private func rectObject(_ rect: ForyRect?) -> Any {
    guard let rect else { return NSNull() }
    return [rect.x, rect.y, rect.w, rect.h]
}

private func normalizeSearchText(_ text: String) -> String {
    text.replacingOccurrences(of: #"[\s\-_:\/()\[\]{}.,'"]"#, with: "", options: .regularExpression)
        .lowercased()
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
    if let double = value as? Double { return Int(double) }
    if let string = value as? String { return Int(string) }
    return nil
}

private func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let int32 = value as? Int32 { return Double(int32) }
    if let string = value as? String { return Double(string) }
    return nil
}

private func target(_ value: String?) throws -> ForyTarget {
    guard let value, !value.isEmpty else { return ForyTarget() }
    if let point = try? pointPair(value) {
        return ForyTarget(label: "", point: point)
    }
    return ForyTarget(label: value, point: nil)
}

private func pointPair(_ value: String) throws -> ForyPoint {
    let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    guard parts.count == 2,
          let x = Double(parts[0]),
          let y = Double(parts[1]) else {
        throw CLIParseError.invalidValue("Invalid point: \"\(value)\"")
    }
    return ForyPoint(x: x, y: y)
}

private func offsetPoint(_ offset: [String: Any]?) throws -> ForyPoint? {
    guard let offset else { return nil }
    if offset["x"] != nil, offset["xRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both x and xRatio")
    }
    if offset["y"] != nil, offset["yRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both y and yRatio")
    }
    guard offset["x"] != nil || offset["y"] != nil else { return nil }
    return ForyPoint(x: number(offset["x"]) ?? 0, y: number(offset["y"]) ?? 0)
}

private func ratioPoint(_ offset: [String: Any]?, hasAbsoluteOffset: Bool) throws -> ForyPoint {
    guard let offset, !hasAbsoluteOffset else { return ForyPoint(x: 0.5, y: 0.5) }
    if offset["x"] != nil, offset["xRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both x and xRatio")
    }
    if offset["y"] != nil, offset["yRatio"] != nil {
        throw CLIParseError.invalidValue("tap offset cannot specify both y and yRatio")
    }
    return ForyPoint(x: number(offset["xRatio"]) ?? 0.5, y: number(offset["yRatio"]) ?? 0.5)
}
