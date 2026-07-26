import Darwin
import Foundation

enum ProbeFailure: Error, CustomStringConvertible {
    case usage
    case pathTooLong
    case systemCall(String, Int32)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: runtime_socket_probe.swift <socket> <oversized-frame|malformed-json|invalid-utf8>"
        case .pathTooLong:
            return "Runtime socket path exceeds sockaddr_un.sun_path"
        case .systemCall(let name, let code):
            return "\(name) failed with errno \(code)"
        case .invalidResponse(let message):
            return "invalid Runtime response: \(message)"
        }
    }
}

func socketAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.hasPrefix("/"),
          !bytes.contains(0),
          bytes.count + 1 <= capacity else {
        throw ProbeFailure.pathTooLong
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
        $0.initializeMemory(as: UInt8.self, repeating: 0)
        $0.copyBytes(from: bytes)
    }
    return address
}

func writeAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    try data.withUnsafeBytes { bytes in
        while offset < data.count {
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                data.count - offset
            )
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw ProbeFailure.systemCall("write", errno)
            }
        }
    }
}

func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    try data.withUnsafeMutableBytes { bytes in
        while offset < count {
            let received = Darwin.read(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                count - offset
            )
            if received > 0 {
                offset += received
            } else if received < 0, errno == EINTR {
                continue
            } else if received == 0 {
                throw ProbeFailure.invalidResponse("unexpected EOF")
            } else {
                throw ProbeFailure.systemCall("read", errno)
            }
        }
    }
    return data
}

func encodeFrame(_ body: Data) -> Data {
    var length = UInt32(body.count).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) } + body
}

func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw ProbeFailure.usage
    }
    let socketPath = CommandLine.arguments[1]
    let mode = CommandLine.arguments[2]
    let expectedCode: String
    let request: Data
    switch mode {
    case "oversized-frame":
        var length = UInt32(65_537).bigEndian
        request = withUnsafeBytes(of: &length) { Data($0) }
        expectedCode = "invalid_frame"
    case "malformed-json":
        request = encodeFrame(Data("{".utf8))
        expectedCode = "invalid_json"
    case "invalid-utf8":
        request = encodeFrame(Data([0xff]))
        expectedCode = "invalid_json"
    default:
        throw ProbeFailure.usage
    }

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw ProbeFailure.systemCall("socket", errno)
    }
    defer { Darwin.close(descriptor) }

    var enabled: Int32 = 1
    guard Darwin.setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        throw ProbeFailure.systemCall("setsockopt", errno)
    }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    guard Darwin.setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else {
        throw ProbeFailure.systemCall("setsockopt", errno)
    }

    var address = try socketAddress(path: socketPath)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard connected == 0 else {
        throw ProbeFailure.systemCall("connect", errno)
    }

    try writeAll(request, descriptor: descriptor)
    let header = try readExactly(4, descriptor: descriptor)
    let responseLength = header.reduce(UInt32(0)) {
        ($0 << 8) | UInt32($1)
    }
    guard responseLength > 0, responseLength <= 1_048_576 else {
        throw ProbeFailure.invalidResponse("invalid response frame length")
    }
    let body = try readExactly(
        Int(responseLength),
        descriptor: descriptor
    )
    guard let object = try JSONSerialization.jsonObject(with: body)
            as? [String: Any],
          (object["schemaVersion"] as? NSNumber)?.intValue == 3,
          (object["ok"] as? NSNumber)?.boolValue == false,
          let error = object["error"] as? [String: Any],
          error["code"] as? String == expectedCode,
          let details = error["details"] as? [String: Any],
          details["category"] as? String == "protocol" else {
        throw ProbeFailure.invalidResponse(
            "missing exact protocol error envelope"
        )
    }

    let output: [String: Any] = [
        "schemaVersion": 1,
        "mode": mode,
        "runtimeErrorCode": expectedCode,
        "runtimeListenerSurvived": true,
    ]
    let encoded = try JSONSerialization.data(
        withJSONObject: output,
        options: [.sortedKeys]
    )
    FileHandle.standardOutput.write(encoded)
    FileHandle.standardOutput.write(Data([0x0a]))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(
        Data("runtime socket probe failed: \(error)\n".utf8)
    )
    exit(1)
}
