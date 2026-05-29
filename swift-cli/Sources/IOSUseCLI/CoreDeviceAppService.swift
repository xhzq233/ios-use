import Foundation

enum CoreDeviceAppServiceError: Error, CustomStringConvertible, Equatable {
    case missingOutput(String)
    case missingOutputResponse(String, String)
    case invalidProcessToken(String)

    var description: String {
        switch self {
        case .missingOutput(let feature):
            return "CoreDevice appservice response missing CoreDevice.output for \(feature)"
        case .missingOutputResponse(let feature, let response):
            return "CoreDevice appservice response missing CoreDevice.output for \(feature): \(response)"
        case .invalidProcessToken(let detail):
            return "CoreDevice appservice invalid process token: \(detail)"
        }
    }
}

struct CoreDeviceProcessToken: Equatable {
    let processIdentifier: Int
    let executable: String
    let bundleIdentifier: String?

    init(processIdentifier: Int, executable: String, bundleIdentifier: String? = nil) {
        self.processIdentifier = processIdentifier
        self.executable = executable
        self.bundleIdentifier = bundleIdentifier
    }
}

final class CoreDeviceAppService {
    static let serviceName = "com.apple.coredevice.appservice"
    static let versionString = "325.3"

    private let client: RemoteXPCClient
    private let uuidProvider: () -> String

    init(client: RemoteXPCClient, uuidProvider: @escaping () -> String = { UUID().uuidString }) {
        self.client = client
        self.uuidProvider = uuidProvider
    }

    static func connect(host: String, peerInfo: RemoteXPCPeerInfo) throws -> CoreDeviceAppService {
        CoreDeviceAppService(
            client: try RemoteServiceDiscoveryClient.connectRemoteXPCService(
                host: host,
                peerInfo: peerInfo,
                serviceName: serviceName
            )
        )
    }

    func close() {
        client.close()
    }

    func launchApplication(
        bundleID: String,
        arguments: [String] = [],
        terminateExisting: Bool = true,
        startSuspended: Bool = false,
        environment: [String: String] = [:],
        payloadURL: String? = nil,
        activates: Bool? = nil
    ) throws -> RemoteXPCValue {
        try invoke(
            featureIdentifier: "com.apple.coredevice.feature.launchapplication",
            input: Self.launchApplicationInput(
                bundleID: bundleID,
                arguments: arguments,
                terminateExisting: terminateExisting,
                startSuspended: startSuspended,
                environment: environment,
                payloadURL: payloadURL,
                activates: activates
            )
        )
    }

    func listProcesses() throws -> [CoreDeviceProcessToken] {
        let output = try invoke(featureIdentifier: "com.apple.coredevice.feature.listprocesses")
        guard let tokens = output.dictionaryValue?["processTokens"] else {
            throw CoreDeviceAppServiceError.missingOutput("com.apple.coredevice.feature.listprocesses.processTokens")
        }
        return try Self.decodeProcessTokens(tokens)
    }

    func sendSignal(processIdentifier: Int, signal: Int) throws -> RemoteXPCValue {
        try invoke(
            featureIdentifier: "com.apple.coredevice.feature.sendsignaltoprocess",
            input: [
                "process": .dictionary([
                    "processIdentifier": .int64(Int64(processIdentifier)),
                ]),
                "signal": .int64(Int64(signal)),
            ]
        )
    }

    func invoke(featureIdentifier: String, input: [String: RemoteXPCValue] = [:]) throws -> RemoteXPCValue {
        let response = try client.sendReceiveRequest(coreDeviceRequest(featureIdentifier: featureIdentifier, input: input))
        guard let output = response.dictionaryValue?["CoreDevice.output"] else {
            throw CoreDeviceAppServiceError.missingOutputResponse(featureIdentifier, Self.describe(response))
        }
        return output
    }

    func coreDeviceRequest(featureIdentifier: String, input: [String: RemoteXPCValue]) -> [String: RemoteXPCValue] {
        return [
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(0),
            "CoreDevice.action": .dictionary([:]),
            "CoreDevice.coreDeviceVersion": Self.coreDeviceVersion(Self.versionString),
            "CoreDevice.deviceIdentifier": .string(uuidProvider()),
            "CoreDevice.featureIdentifier": .string(featureIdentifier),
            "CoreDevice.input": .dictionary(input),
            "CoreDevice.invocationIdentifier": .string(uuidProvider()),
        ]
    }

    static func coreDeviceVersion(_ version: String) -> RemoteXPCValue {
        let components = version.split(separator: ".").map { UInt64($0) ?? 0 }
        return .dictionary([
            "components": .array(components.map { .uint64($0) }),
            "originalComponentsCount": .int64(Int64(components.count)),
            "stringValue": .string(version),
        ])
    }

    static func launchApplicationInput(
        bundleID: String,
        arguments: [String] = [],
        terminateExisting: Bool = true,
        startSuspended: Bool = false,
        environment: [String: String] = [:],
        payloadURL: String? = nil,
        activates: Bool? = nil
    ) -> [String: RemoteXPCValue] {
        var options: [String: RemoteXPCValue] = [
            "arguments": .array(arguments.map { .string($0) }),
            "environmentVariables": .dictionary(environment.mapValues { .string($0) }),
            "platformSpecificOptions": .data(emptyPlistData()),
            "standardIOUsesPseudoterminals": .bool(true),
            "startStopped": .bool(startSuspended),
            "terminateExisting": .bool(terminateExisting),
            "user": .dictionary([
                "shortName": .string("mobile"),
            ]),
        ]
        if let payloadURL {
            options["payloadURL"] = remoteURL(payloadURL)
        }
        if let activates {
            options["activates"] = .bool(activates)
        }

        return [
            "applicationSpecifier": .dictionary([
                "bundleIdentifier": .dictionary([
                    "_0": .string(bundleID),
                ]),
            ]),
            "options": .dictionary(options),
            "standardIOIdentifiers": .dictionary([:]),
        ]
    }

    static func decodeProcessTokens(_ value: RemoteXPCValue) throws -> [CoreDeviceProcessToken] {
        guard case .array(let tokenValues) = value else {
            throw CoreDeviceAppServiceError.invalidProcessToken("processTokens is not an array")
        }
        return try tokenValues.map { tokenValue in
            guard let token = tokenValue.dictionaryValue else {
                throw CoreDeviceAppServiceError.invalidProcessToken("token is not a dictionary")
            }
            guard let pid = token["processIdentifier"]?.intValue else {
                throw CoreDeviceAppServiceError.invalidProcessToken("missing processIdentifier")
            }
            let executable = Self.extractExecutable(from: token["executable"])
                .nonEmptyOrNil
                ?? Self.extractExecutable(from: .dictionary(token))
            let bundleIdentifier = Self.extractBundleIdentifier(from: token)
            return CoreDeviceProcessToken(processIdentifier: pid, executable: executable, bundleIdentifier: bundleIdentifier)
        }
    }

    static func extractProcessIdentifier(from value: RemoteXPCValue) -> Int? {
        switch value {
        case .dictionary(let dictionary):
            if let pid = dictionary["processIdentifier"]?.intValue {
                return pid
            }
            for key in ["processToken", "process", "token"] {
                if let pid = dictionary[key].flatMap(extractProcessIdentifier) {
                    return pid
                }
            }
            for key in dictionary.keys.sorted() {
                if let pid = dictionary[key].flatMap(extractProcessIdentifier) {
                    return pid
                }
            }
            return nil
        case .array(let values):
            for value in values {
                if let pid = extractProcessIdentifier(from: value) {
                    return pid
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func extractExecutable(from value: RemoteXPCValue?) -> String {
        guard let value else { return "" }
        if let executable = value.stringValue {
            return executable
        }
        let strings = collectStrings(value)
        if let executable = strings.first(where: { $0.contains("IOSUseDriver-Runner") }) {
            return executable
        }
        if let fileURL = strings.first(where: { $0.hasPrefix("file:") }) {
            return fileURL
        }
        if let path = strings.first(where: { $0.contains("/") }) {
            return path
        }
        return strings.first ?? ""
    }

    private static func extractBundleIdentifier(from token: [String: RemoteXPCValue]) -> String? {
        for key in ["bundleIdentifier", "bundleID", "applicationIdentifier", "applicationBundleIdentifier"] {
            if let value = token[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func collectStrings(_ value: RemoteXPCValue) -> [String] {
        switch value {
        case .string(let string):
            return [string]
        case .array(let values):
            return values.flatMap(collectStrings)
        case .dictionary(let dictionary):
            return dictionary.keys.sorted().flatMap { key in
                dictionary[key].map(collectStrings) ?? []
            }
        default:
            return []
        }
    }

    private static func emptyPlistData() -> Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: [:],
            format: .xml,
            options: 0
        )) ?? Data()
    }

    private static func remoteURL(_ url: String) -> RemoteXPCValue {
        .dictionary([
            "relative": .string(url),
        ])
    }

    private static func describe(_ value: RemoteXPCValue, depth: Int = 0) -> String {
        if depth >= 4 {
            return "..."
        }
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return "bool(\(value))"
        case .int64(let value):
            return "int64(\(value))"
        case .uint64(let value):
            return "uint64(\(value))"
        case .double(let value):
            return "double(\(value))"
        case .date(let value):
            return "date(\(value))"
        case .string(let value):
            return "string(\(quote(value)))"
        case .data(let data):
            return "data(\(data.count))"
        case .uuid(let value):
            return "uuid(\(value.uuidString))"
        case .array(let values):
            let rendered = values.prefix(5).map { describe($0, depth: depth + 1) }
            let suffix = values.count > 5 ? ", ..." : ""
            return "array(\(values.count))[\(rendered.joined(separator: ", "))\(suffix)]"
        case .dictionary(let dictionary):
            let rendered = dictionary.keys.sorted().prefix(8).map { key in
                "\(key): \(dictionary[key].map { describe($0, depth: depth + 1) } ?? "missing")"
            }
            let suffix = dictionary.count > 8 ? ", ..." : ""
            return "dictionary{\(rendered.joined(separator: ", "))\(suffix)}"
        }
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        if escaped.count <= 160 {
            return "\"\(escaped)\""
        }
        return "\"\(escaped.prefix(160))...\""
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
