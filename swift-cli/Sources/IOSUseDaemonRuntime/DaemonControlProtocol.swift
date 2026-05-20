import Foundation

public enum DaemonControlProtocol {
    public static let version = 1

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encode(_ message: DaemonControlMessage) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0a)
        return data
    }

    public static func decode(_ data: Data) throws -> DaemonControlMessage {
        let trimmed = data.trimmedDaemonFrameNewline()
        let message = try decoder.decode(DaemonControlMessage.self, from: trimmed)
        guard message.version == version else {
            throw CLIParseError.invalidValue("unsupported daemon protocol version: \(message.version)")
        }
        return message
    }
}

public enum DaemonControlMessage: Codable, Equatable, Sendable {
    case request(DaemonRequest)
    case interrupt(DaemonInterrupt)
    case exit(DaemonExit)

    public var version: Int {
        switch self {
        case .request(let request): return request.version
        case .interrupt(let interrupt): return interrupt.version
        case .exit(let exit): return exit.version
        }
    }

    public var id: String {
        switch self {
        case .request(let request): return request.id
        case .interrupt(let interrupt): return interrupt.id
        case .exit(let exit): return exit.id
        }
    }
}

public struct DaemonRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var argv: [String]
    public var cwd: String
    public var environment: [String: String]

    public init(
        version: Int = DaemonControlProtocol.version,
        id: String = UUID().uuidString,
        argv: [String],
        cwd: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = [:]
    ) {
        self.version = version
        self.id = id
        self.argv = argv
        self.cwd = cwd
        self.environment = environment
    }
}

public struct DaemonInterrupt: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var signal: String

    public init(version: Int = DaemonControlProtocol.version, id: String, signal: String) {
        self.version = version
        self.id = id
        self.signal = signal
    }
}

public struct DaemonExit: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var exitCode: Int32

    public init(version: Int = DaemonControlProtocol.version, id: String, exitCode: Int32) {
        self.version = version
        self.id = id
        self.exitCode = exitCode
    }
}

private extension Data {
    func trimmedDaemonFrameNewline() -> Data {
        guard last == 0x0a else { return self }
        return dropLast()
    }
}
