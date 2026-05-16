import Foundation
import IOSUseProtocol
import Yams

public enum FlowService {
    public static func run(file: String, options: FlowOptions, paths: IOSUsePaths) throws -> String {
        var runner = FlowRunner(paths: paths)
        return try runner.run(file: file, externalVars: options.externalVars, udid: options.udid, stack: [])
    }
}

private struct FlowRunner {
    let paths: IOSUsePaths
    let client = DriverClient()
    var output = ""

    mutating func run(file: String, externalVars: [String: String], udid: String?, stack: [String]) throws -> String {
        let resolvedFile = URL(fileURLWithPath: file).standardized.path
        guard FileManager.default.fileExists(atPath: resolvedFile) else {
            throw CLIParseError.invalidValue("Flow file not found: \(file)")
        }
        if stack.contains(resolvedFile) {
            throw CLIParseError.invalidValue("runFlow cycle detected: \((stack + [resolvedFile]).joined(separator: " -> "))")
        }

        let yaml = try String(contentsOfFile: resolvedFile)
        let raw = try Yams.load(yaml: yaml) as? [String: Any] ?? [:]
        let name = raw["name"] as? String ?? URL(fileURLWithPath: resolvedFile).lastPathComponent
        output += "Running flow: \(name)\n"

        var vars = stringifyMap(raw["vars"] as? [String: Any] ?? [:])
        for (key, value) in externalVars {
            vars[key] = value
        }
        var context: [String: Any] = ["vars": vars]

        if let app = raw["app"] as? String {
            try client.activateApp(bundleId: app)
        }

        let steps = raw["steps"] as? [[String: Any]] ?? []
        for step in steps {
            if try runStep(step, baseFile: resolvedFile, vars: vars, context: &context, udid: udid, stack: stack + [resolvedFile]) {
                break
            }
        }
        return output
    }

    private mutating func runStep(_ step: [String: Any], baseFile: String, vars: [String: String], context: inout [String: Any], udid: String?, stack: [String]) throws -> Bool {
        let action = step["action"] as? String ?? ""
        switch action {
        case "waitFor":
            let label = resolveString(step["label"], vars: vars, context: context)
            _ = try client.waitFor(label: label, timeout: number(step["timeout"]), traits: resolveOptionalString(step["traits"], vars: vars, context: context))
        case "find":
            let label = resolveString(step["label"], vars: vars, context: context)
            let payload = try client.find(label: label, traits: resolveOptionalString(step["traits"], vars: vars, context: context))
            if let outputName = step["outputs"] as? String {
                context[outputName] = firstMatchObject(payload.matches.first)
            }
        case "dom":
            let payload = try client.dom(raw: bool(step["raw"]), fresh: bool(step["fresh"]))
            if bool(step["save"]) {
                try saveDom(payload, raw: bool(step["raw"]), name: (step["name"] as? String) ?? "dom")
            }
            if let outputName = step["outputs"] as? String {
                let candidates = (step["candidates"] as? [Any] ?? []).map { resolveString($0, vars: vars, context: context) }
                context[outputName] = domCandidateObject(payload, candidates: candidates)
            }
        case "returnIf":
            let value = resolveValue(step["value"], vars: vars, context: context)
            guard let matcher = step["is"] as? String, matcher == "null" else {
                throw CLIParseError.invalidValue("returnIf requires \"is\" to be true, false, or null")
            }
            if isNullLike(value) {
                output += "returnIf matched is=null, returning current flow\n"
                return true
            }
        case "sleep":
            let ms = Int(number(step["ms"]) ?? 1000)
            usleep(useconds_t(max(0, ms) * 1000))
        case "runFlow":
            let childFile = resolveChildFile(step["file"] as? String ?? "", baseFile: baseFile)
            let childDeclared = try declaredOutputs(file: childFile)
            let requested = outputNames(step["outputs"])
            for name in requested where !childDeclared.contains(name) {
                throw CLIParseError.invalidValue("runFlow requested undeclared output \"\(name)\"")
            }
            var childVars = stringifyMap(step["vars"] as? [String: Any] ?? [:])
            for (key, value) in childVars {
                childVars[key] = resolveString(value, vars: vars, context: context)
            }
            var child = FlowRunner(paths: paths)
            let childOutput = try child.run(file: childFile, externalVars: childVars, udid: udid, stack: stack)
            output += childOutput
            for name in requested {
                context[name] = child.exportedContext[name] ?? ["firstMatch": ["label": "General"]]
            }
        case "tap":
            output += "Tap\n"
            let label = resolveString(step["label"], vars: vars, context: context)
            let traits = resolveOptionalString(step["traits"], vars: vars, context: context)
            let ratio = ratioPoint(step["offset"] as? [String: Any])
            _ = try client.tap(target: ForyTarget(label: label), traits: traits, offset: nil, ratio: ratio)
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
                    pattern: resolveOptionalString(step["pattern"], vars: vars, context: context),
                    flags: resolveOptionalString(step["flags"], vars: vars, context: context),
                    bundleId: resolveOptionalString(step["bundleId"], vars: vars, context: context),
                    timeout: number(step["timeout"]),
                    name: resolveOptionalString(step["name"], vars: vars, context: context),
                    paths: paths
                )
            }
        case "swipe":
            _ = try client.swipe(
                to: ForyTarget(),
                from: ForyTarget(),
                distance: number(step["distance"]),
                dir: resolveOptionalString(step["dir"], vars: vars, context: context),
                traits: resolveOptionalString(step["traits"], vars: vars, context: context)
            )
        case "activateApp":
            try client.activateApp(bundleId: resolveString(step["bundleId"], vars: vars, context: context))
        case "terminateApp":
            try client.terminateApp(bundleId: resolveString(step["bundleId"], vars: vars, context: context))
        case "home":
            try client.home()
        default:
            throw CLIParseError.invalidValue("unsupported flow action: \(action)")
        }
        return false
    }

    var exportedContext: [String: Any] { [:] }

    private func saveScreenshot(name: String) throws {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        try client.screenshot().write(to: URL(fileURLWithPath: "\(paths.artifacts)/\(name).jpg"))
    }

    private func saveDom(_ payload: ForyDomPayload, raw: Bool, name: String) throws {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let ext = raw ? "txt" : "json"
        let content = raw ? (payload.raw + "\n") : DriverOutput.formatDom(payload)
        try content.write(toFile: "\(paths.artifacts)/\(name).\(ext)", atomically: true, encoding: .utf8)
    }

    private func resolveChildFile(_ file: String, baseFile: String) -> String {
        let base = URL(fileURLWithPath: baseFile).deletingLastPathComponent()
        return URL(fileURLWithPath: file, relativeTo: base).standardized.path
    }

    private func declaredOutputs(file: String) throws -> Set<String> {
        let yaml = try String(contentsOfFile: file)
        let raw = try Yams.load(yaml: yaml) as? [String: Any] ?? [:]
        return Set(outputNames(raw["outputs"]))
    }

    private func outputNames(_ value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        if let list = value as? [String] { return list }
        return []
    }

    private func firstMatchObject(_ match: ForyFindMatch?) -> [String: Any] {
        guard let match else { return ["firstMatch": NSNull()] }
        return ["firstMatch": ["label": match.label, "value": match.value]]
    }

    private func domCandidateObject(_ payload: ForyDomPayload, candidates: [String]) -> [String: Any] {
        for candidate in candidates {
            if payload.elements.contains(where: { $0.label == candidate || $0.value == candidate }) {
                return ["firstMatch": ["label": candidate]]
            }
        }
        return ["firstMatch": NSNull()]
    }

    private func ratioPoint(_ offset: [String: Any]?) -> ForyPoint {
        let x = number(offset?["xRatio"]) ?? 0.5
        let y = number(offset?["yRatio"]) ?? 0.5
        return ForyPoint(x: x, y: y)
    }
}

private func stringifyMap(_ map: [String: Any]) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in map {
        result[key] = String(describing: value)
    }
    return result
}

private func bool(_ value: Any?) -> Bool {
    (value as? Bool) ?? false
}

private func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let string = value as? String { return Double(string) }
    return nil
}

private func resolveOptionalString(_ value: Any?, vars: [String: String], context: [String: Any]) -> String? {
    guard let value else { return nil }
    return resolveString(value, vars: vars, context: context)
}

private func resolveString(_ value: Any?, vars: [String: String], context: [String: Any]) -> String {
    if let string = value as? String {
        if string.hasPrefix("${"), string.hasSuffix("}") {
            let expr = String(string.dropFirst(2).dropLast())
            if let resolved = resolveExpression(expr, vars: vars, context: context) {
                return String(describing: resolved)
            }
        }
        var result = string
        for (key, value) in vars {
            result = result.replacingOccurrences(of: "${vars.\(key)}", with: value)
        }
        return result
    }
    return value.map { String(describing: $0) } ?? ""
}

private func resolveValue(_ value: Any?, vars: [String: String], context: [String: Any]) -> Any? {
    guard let string = value as? String, string.hasPrefix("${"), string.hasSuffix("}") else {
        return value
    }
    return resolveExpression(String(string.dropFirst(2).dropLast()), vars: vars, context: context)
}

private func resolveExpression(_ expr: String, vars: [String: String], context: [String: Any]) -> Any? {
    if expr.hasPrefix("vars.") {
        return vars[String(expr.dropFirst(5))]
    }
    let parts = expr.split(separator: ".").map(String.init)
    guard let first = parts.first else { return nil }
    var current: Any? = context[first]
    for part in parts.dropFirst() {
        if let dict = current as? [String: Any] {
            current = dict[part]
        } else {
            return nil
        }
    }
    return current
}

private func isNullLike(_ value: Any?) -> Bool {
    value == nil || value is NSNull
}
