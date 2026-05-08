import Foundation

// MARK: - Command

enum Command: String, Codable {
    case createSession
    case deleteSession
    case activateApp
    case terminateApp
    case openURL
    case probeFetch
    case proxyStart
    case proxyStop
    case proxyIngressStart
    case proxyIngressStop
    case proxyPushProfile
    case screenshot
    case oslog
    case dom
    case find
    case tap
    case longPress
    case input
    case swipe
    case waitFor
}

// MARK: - SwipeDir (doc 3.1 — forth/back only)

enum SwipeDir: String, Codable {
    case forth
    case back
}

// MARK: - StringOrPoint (doc 1.2 — label or [x, y])

/// Shared between tap/longPress/swipe/etc.
/// Decodes either a String (label) or a 2-element [Double] (absolute point).
enum StringOrPoint: Codable {
    case label(String)
    case point([Double])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .label(s)
            return
        }
        if let a = try? c.decode([Double].self), a.count == 2 {
            self = .point(a)
            return
        }
        throw DecodingError.typeMismatch(
            StringOrPoint.self,
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "Expected String or [Double] of length 2")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .label(let s): try c.encode(s)
        case .point(let p): try c.encode(p)
        }
    }

    var asLabel: String? {
        if case .label(let s) = self { return s }
        return nil
    }

    var asPoint: [Double]? {
        if case .point(let p) = self { return p }
        return nil
    }
}

// MARK: - LabelContext (doc 3.2)

struct LabelContext: Codable {
    let ancestorType: String?
    let ancestorLabel: String?
}

// MARK: - Per-command Args (doc 1.2 & 6.x)

struct CreateSessionArgs: Codable {
    let bundleId: String?
}

struct ActivateAppArgs: Codable {
    let bundleId: String
}

struct TerminateAppArgs: Codable {
    let bundleId: String
}

struct OpenURLArgs: Codable {
    let url: String
}

/// doc 6.4
struct OslogArgs: Codable {
    let pattern: String?
    let flags: String?
    let name: String?
    let clear: Bool?
    let bundleId: String?
    let timeout: Double?
}

struct ProbeFetchArgs: Codable {
    let url: String
    let timeout: Double?
}

struct TapOffset: Codable {
    let x: Double?
    let y: Double?
    let xRatio: Double?
    let yRatio: Double?
}

struct DomArgs: Codable {
    let raw: Bool?
    let fresh: Bool?
}

struct FindArgs: Codable {
    let label: String
    let context: LabelContext?
}

struct TapArgs: Codable {
    let label: StringOrPoint
    let context: LabelContext?
    let offset: TapOffset?
}

struct LongPressArgs: Codable {
    let label: StringOrPoint
    let duration: Double?
    let context: LabelContext?
}

struct InputArgs: Codable {
    let label: String
    let content: String
    let context: LabelContext?
}

/// doc 3.1
struct SwipeArgs: Codable {
    let to: StringOrPoint?
    let from: StringOrPoint?
    let distance: Double?
    let dir: SwipeDir?
    let context: LabelContext?
}

/// doc 6.5
struct WaitForArgs: Codable {
    let label: String
    let timeout: Double?
    let context: LabelContext?
}

// MARK: - Request/Response frames

/// Each command carries its own Args type; the dispatcher re-decodes `args`
/// using the correct type. `args` is kept as raw JSON via AnyCodable.
struct RequestFrame: Decodable {
    let c: Command
    let args: AnyCodable?
}

struct ResponseFrame: Codable {
    let ok: Bool
    let error: String?
    let data: AnyCodable?
}

// MARK: - DriverError

enum DriverError: Error {
    case noSession
    case invalidArgs(String)
    case appNotFound(String)
    case elementNotFound(String)
    case ambiguous(String)
    case timeout(String)
    case atBoundary(String)
    case serverError(String)
}

extension DriverError: CustomStringConvertible {
    var description: String {
        switch self {
        case .noSession: return "no active session"
        case .invalidArgs(let s): return "invalid arguments: \(s)"
        case .appNotFound(let s): return "app not found: \(s)"
        case .elementNotFound(let s): return "element not found: \(s)"
        case .ambiguous(let s): return "ambiguous: \(s)"
        case .timeout(let s): return "timeout: \(s)"
        case .atBoundary(let s): return "at boundary: \(s)"
        case .serverError(let s): return "server error: \(s)"
        }
    }
}

// MARK: - AnyCodable (kept from old)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull(); return }
        if let v = try? container.decode(Bool.self) { value = v; return }
        if let v = try? container.decode(Int.self) { value = v; return }
        if let v = try? container.decode(Double.self) { value = v; return }
        if let v = try? container.decode(String.self) { value = v; return }
        if let v = try? container.decode([AnyCodable].self) {
            value = v.map { $0.value }
            return
        }
        if let v = try? container.decode([String: AnyCodable].self) {
            var dict: [String: Any] = [:]
            for (k, vv) in v { dict[k] = vv.value }
            value = dict
            return
        }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let v as String: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as [String: Any]:
            var nested = encoder.container(keyedBy: JSONCodingKeys.self)
            try encodeDict(v, into: &nested)
        case let v as [Any]:
            var nested = encoder.unkeyedContainer()
            try encodeArray(v, into: &nested)
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional && mirror.children.isEmpty {
                try container.encodeNil()
            } else {
                try container.encodeNil()
            }
        }
    }

    private func encodeDict(_ dict: [String: Any], into container: inout KeyedEncodingContainer<JSONCodingKeys>) throws {
        for (key, val) in dict {
            let codingKey = JSONCodingKeys(key: key)
            switch val {
            case is NSNull: try container.encodeNil(forKey: codingKey)
            case let v as String: try container.encode(v, forKey: codingKey)
            case let v as Int: try container.encode(v, forKey: codingKey)
            case let v as Double: try container.encode(v, forKey: codingKey)
            case let v as Bool: try container.encode(v, forKey: codingKey)
            case let v as [String: Any]:
                var nested = container.nestedContainer(keyedBy: JSONCodingKeys.self, forKey: codingKey)
                try encodeDict(v, into: &nested)
            case let v as [Any]:
                var nested = container.nestedUnkeyedContainer(forKey: codingKey)
                try encodeArray(v, into: &nested)
            default: try container.encodeNil(forKey: codingKey)
            }
        }
    }

    private func encodeArray(_ arr: [Any], into container: inout UnkeyedEncodingContainer) throws {
        for val in arr {
            switch val {
            case is NSNull: try container.encodeNil()
            case let v as String: try container.encode(v)
            case let v as Int: try container.encode(v)
            case let v as Double: try container.encode(v)
            case let v as Bool: try container.encode(v)
            case let v as [String: Any]:
                var nested = container.nestedContainer(keyedBy: JSONCodingKeys.self)
                try encodeDict(v, into: &nested)
            case let v as [Any]:
                var nested = container.nestedUnkeyedContainer()
                try encodeArray(v, into: &nested)
            default: try container.encodeNil()
            }
        }
    }
}

struct JSONCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    init(key: String) { self.stringValue = key }
}

// MARK: - Helpers

extension Double {
    var sanitized: Double { isFinite ? (self * 10).rounded(.toNearestOrEven) / 10 : 0 }
}

// MARK: - Args decode helper

/// Decode typed args from RequestFrame.args (doc §1 per-command args).
func decodeArgs<T: Decodable>(_ raw: AnyCodable?, as type: T.Type) throws -> T {
    guard let raw = raw else {
        throw DriverError.invalidArgs("missing args")
    }
    // Re-encode AnyCodable → JSON, then decode as target type.
    let data: Data
    do {
        data = try JSONEncoder().encode(raw)
    } catch {
        throw DriverError.invalidArgs("encode args: \(error)")
    }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw DriverError.invalidArgs("decode \(T.self): \(error)")
    }
}

/// Same as decodeArgs but returns nil when args is absent (for commands whose
/// args are entirely optional, e.g. createSession, dom).
func decodeArgsOptional<T: Decodable>(_ raw: AnyCodable?, as type: T.Type) -> T? {
    guard let raw = raw else { return nil }
    guard let data = try? JSONEncoder().encode(raw) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
