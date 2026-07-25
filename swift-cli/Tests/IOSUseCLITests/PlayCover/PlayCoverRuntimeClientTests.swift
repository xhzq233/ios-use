import Darwin
import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverRuntimeClientTests: XCTestCase {
    func testHelloSendsExactIdentityAndDecodesPayloadFromSameUIDPeer() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let nonce = "launch-secret"
        let server = try FakeUnixRuntimeServer(socketPath: fixture.socketPath) { request in
            XCTAssertEqual(request["schemaVersion"] as? Int, 1)
            XCTAssertEqual(request["command"] as? String, "hello")
            XCTAssertEqual(request["launchNonce"] as? String, nonce)
            let requestID = try XCTUnwrap(request["requestId"] as? String)
            XCTAssertNotNil(UUID(uuidString: requestID))
            return .json(
                try self.response(
                    requestID: requestID,
                    payload: self.payload(
                        nonce: nonce,
                        socketPath: fixture.socketPath
                    )
                ),
                chunkSize: 1
            )
        }

        let result = try PlayCoverRuntimeClient(
            socketPath: fixture.socketPath,
            launchNonce: nonce
        ).hello()
        try server.wait()

        XCTAssertEqual(server.peerUID, geteuid())
        XCTAssertEqual(result.protocolVersion, 1)
        XCTAssertEqual(result.pid, 4_242)
        XCTAssertEqual(result.bundleIdentifier, "com.example.runtime")
        XCTAssertEqual(result.profileHash, "profile-hash")
        XCTAssertEqual(result.preparedGenerationID, "generation-1")
        XCTAssertEqual(result.runtimeSocketPath, fixture.socketPath)
        XCTAssertEqual(result.runtimeInstanceID, "runtime-1")
        XCTAssertEqual(result.launchNonce, nonce)
        XCTAssertEqual(result.capabilities, ["hello", "ping", "diagnostics"])
        XCTAssertEqual(result.logicalWidth, 430)
        XCTAssertEqual(result.logicalHeight, 932)
        XCTAssertEqual(result.nativeWidth, 1_290)
        XCTAssertEqual(result.nativeHeight, 2_796)
        XCTAssertEqual(result.scale, 3)
        XCTAssertEqual(result.windowWidth, 430)
        XCTAssertEqual(result.windowHeight, 932)
        XCTAssertEqual(result.stage, "window-fixed")
        XCTAssertEqual(
            result.observed?["screen"],
            .object(["scale": .number(3)])
        )
    }

    func testPingAndDiagnosticsSendTheirExactCommands() throws {
        for command in ["ping", "diagnostics"] {
            let fixture = try RuntimeClientFixture()
            defer { fixture.remove() }
            let server = try FakeUnixRuntimeServer(socketPath: fixture.socketPath) { request in
                XCTAssertEqual(request["command"] as? String, command)
                let requestID = try XCTUnwrap(request["requestId"] as? String)
                return .json(
                    try self.response(
                        requestID: requestID,
                        payload: self.payload(
                            nonce: "nonce",
                            socketPath: fixture.socketPath
                        )
                    )
                )
            }
            let client = PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: "nonce"
            )

            let payload = command == "ping"
                ? try client.ping()
                : try client.diagnostics()

            XCTAssertEqual(payload.runtimeInstanceID, "runtime-1")
            try server.wait()
        }
    }

    func testSuccessfulResponseWithWrongNonceIsRejectedWithoutExposingNonce() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let expectedNonce = "expected-private-nonce"
        let returnedNonce = "wrong-private-nonce"
        let server = try FakeUnixRuntimeServer(socketPath: fixture.socketPath) { request in
            let requestID = try XCTUnwrap(request["requestId"] as? String)
            return .json(
                try self.response(
                    requestID: requestID,
                    payload: self.payload(
                        nonce: returnedNonce,
                        socketPath: fixture.socketPath
                    )
                )
            )
        }

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: expectedNonce
            ).hello()
        ) { error in
            XCTAssertEqual(
                error as? PlayCoverRuntimeClientError,
                .launchNonceMismatch
            )
            XCTAssertFalse(String(describing: error).contains(expectedNonce))
            XCTAssertFalse(String(describing: error).contains(returnedNonce))
        }
        try server.wait()
    }

    func testRemoteNonceErrorRedactsNonce() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let nonce = "do-not-disclose-this-nonce"
        let server = try FakeUnixRuntimeServer(socketPath: fixture.socketPath) { request in
            let requestID = try XCTUnwrap(request["requestId"] as? String)
            return .json(
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1,
                    "requestId": requestID,
                    "ok": false,
                    "error": [
                        "code": "nonceMismatch",
                        "message": "rejected \(nonce)",
                    ],
                ])
            )
        }

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: nonce
            ).hello()
        ) { error in
            XCTAssertEqual(
                error as? PlayCoverRuntimeClientError,
                .remoteError(
                    code: "nonceMismatch",
                    message: "rejected <redacted>"
                )
            )
            XCTAssertFalse(String(describing: error).contains(nonce))
        }
        try server.wait()
    }

    func testMismatchedRequestIDIsRejected() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(socketPath: fixture.socketPath) { _ in
            .json(
                try self.response(
                    requestID: UUID().uuidString,
                    payload: self.payload(
                        nonce: "nonce",
                        socketPath: fixture.socketPath
                    )
                )
            )
        }

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: "nonce"
            ).hello()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .requestIDMismatch
            )
        }
        try server.wait()
    }

    func testOversizedResponseIsRejectedBeforeBodyRead() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(socketPath: fixture.socketPath) { _ in
            .lengthOnly(UInt32(PlayCoverRuntimeClient.maximumBodyBytes + 1))
        }

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: "nonce"
            ).hello()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .responseFrameTooLarge(
                    actualBytes: PlayCoverRuntimeClient.maximumBodyBytes + 1,
                    maximumBytes: PlayCoverRuntimeClient.maximumBodyBytes
                )
            )
        }
        try server.wait()
    }

    func testOversizedRequestIsRejectedBeforeConnecting() {
        let nonce = String(
            repeating: "n",
            count: PlayCoverRuntimeClient.maximumBodyBytes
        )

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: "/tmp/does-not-need-to-exist.sock",
                launchNonce: nonce
            ).hello()
        ) {
            guard case .requestFrameTooLarge(let actual, let maximum) =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, PlayCoverRuntimeClient.maximumBodyBytes)
            XCTAssertFalse(String(describing: $0).contains(nonce))
        }
    }

    func testEmptyResponseFrameIsRejected() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(socketPath: fixture.socketPath) { _ in
            .lengthOnly(0)
        }

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: "nonce"
            ).hello()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .emptyResponseFrame
            )
        }
        try server.wait()
    }

    func testNonUTF8ResponseIsRejected() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(socketPath: fixture.socketPath) { _ in
            .body(Data([0xC3, 0x28]))
        }

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: "nonce"
            ).hello()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .responseIsNotUTF8
            )
        }
        try server.wait()
    }

    func testNULInSocketPathIsRejected() {
        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: "/tmp/runtime\u{0}.sock",
                launchNonce: "nonce"
            ).hello()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .invalidSocketPath(.containsNUL)
            )
        }
    }

    func testSocketPathUsesUTF8ByteLimitIncludingTerminator() {
        let address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = "/" + String(repeating: "é", count: capacity / 2)

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: path,
                launchNonce: "nonce"
            ).hello()
        ) {
            guard case .invalidSocketPath(
                .tooLong(let actual, let maximum)
            ) = $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(actual, path.utf8.count)
            XCTAssertEqual(maximum, capacity - 1)
        }
    }

    func testMissingUnixSocketFailsWithoutTCPFallback() {
        let fixture = try? RuntimeClientFixture()
        guard let fixture else {
            return XCTFail("cannot create fixture directory")
        }
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: "nonce"
            ).hello()
        ) {
            guard case .connectFailed(let code) =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(code, ENOENT)
        }
    }

    func testResponseDripCannotExtendAbsoluteRequestDeadline() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { _ in
            .drip(
                Data(repeating: 0x20, count: 64),
                delayMicroseconds: 10_000
            )
        }
        let started = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(
            try PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                launchNonce: "nonce",
                timeoutSeconds: 0.05
            ).hello()
        ) {
            guard case .timeout =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - started,
            0.3
        )
        _ = try? server.wait()
    }

    private func payload(
        nonce: String,
        socketPath: String
    ) -> [String: Any] {
        [
            "protocolVersion": 1,
            "pid": 4_242,
            "bundleIdentifier": "com.example.runtime",
            "profileHash": "profile-hash",
            "preparedGenerationID": "generation-1",
            "runtimeSocketPath": socketPath,
            "runtimeInstanceID": "runtime-1",
            "launchNonce": nonce,
            "capabilities": ["hello", "ping", "diagnostics"],
            "logicalWidth": 430,
            "logicalHeight": 932,
            "nativeWidth": 1_290,
            "nativeHeight": 2_796,
            "scale": 3,
            "windowWidth": 430,
            "windowHeight": 932,
            "stage": "window-fixed",
            "observed": [
                "screen": ["scale": 3],
            ],
        ]
    }

    private func response(
        requestID: String,
        payload: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "requestId": requestID,
            "ok": true,
            "payload": payload,
        ])
    }
}

private struct RuntimeClientFixture {
    let root: String
    let socketPath: String

    init() throws {
        root = "/tmp/iosuse-pc-\(UUID().uuidString.prefix(8))"
        socketPath = "\(root)/r.sock"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

private final class FakeUnixRuntimeServer {
    enum Reply {
        case json(Data, chunkSize: Int = .max)
        case body(Data, chunkSize: Int = .max)
        case lengthOnly(UInt32)
        case drip(Data, delayMicroseconds: useconds_t)
    }

    private let socketPath: String
    private let listener: Int32
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var runError: Error?
    private var recordedPeerUID: uid_t?

    var peerUID: uid_t? {
        lock.withLock { recordedPeerUID }
    }

    init(
        socketPath: String,
        handler: @escaping ([String: Any]) throws -> Reply
    ) throws {
        self.socketPath = socketPath
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw FakeUnixRuntimeServerError.systemCall("socket", errno)
        }

        do {
            var enabled: Int32 = 1
            guard Darwin.setsockopt(
                listener,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw FakeUnixRuntimeServerError.systemCall(
                    "setsockopt",
                    errno
                )
            }
            var address = try Self.address(for: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        listener,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw FakeUnixRuntimeServerError.systemCall("bind", errno)
            }
            guard Darwin.listen(listener, 1) == 0 else {
                throw FakeUnixRuntimeServerError.systemCall("listen", errno)
            }
        } catch {
            Darwin.close(listener)
            Darwin.unlink(socketPath)
            throw error
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                Darwin.close(listener)
                Darwin.unlink(socketPath)
                completion.signal()
            }
            do {
                try run(handler: handler)
            } catch {
                lock.withLock {
                    runError = error
                }
            }
        }
    }

    deinit {
        Darwin.unlink(socketPath)
    }

    func wait(timeout: TimeInterval = 2) throws {
        guard completion.wait(timeout: .now() + timeout) == .success else {
            throw FakeUnixRuntimeServerError.timedOut
        }
        if let error = lock.withLock({ runError }) {
            throw error
        }
    }

    private func run(
        handler: ([String: Any]) throws -> Reply
    ) throws {
        let client: Int32
        while true {
            let accepted = Darwin.accept(listener, nil, nil)
            if accepted >= 0 {
                client = accepted
                break
            }
            if errno != EINTR {
                throw FakeUnixRuntimeServerError.systemCall("accept", errno)
            }
        }
        defer { Darwin.close(client) }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0 else {
            throw FakeUnixRuntimeServerError.systemCall("getpeereid", errno)
        }
        lock.withLock {
            recordedPeerUID = peerUID
        }

        let body = try Self.readFrame(from: client)
        let object = try JSONSerialization.jsonObject(with: body)
        guard let request = object as? [String: Any] else {
            throw FakeUnixRuntimeServerError.invalidRequest
        }

        switch try handler(request) {
        case .json(let body, let chunkSize), .body(let body, let chunkSize):
            var length = UInt32(body.count).bigEndian
            let header = withUnsafeBytes(of: &length) { Data($0) }
            try Self.write(
                header + body,
                to: client,
                maximumChunkSize: chunkSize
            )
        case .drip(let body, let delayMicroseconds):
            var length = UInt32(body.count).bigEndian
            let header = withUnsafeBytes(of: &length) { Data($0) }
            try Self.write(
                header + body,
                to: client,
                maximumChunkSize: 1,
                delayMicroseconds: delayMicroseconds
            )
        case .lengthOnly(var length):
            length = length.bigEndian
            try withUnsafeBytes(of: &length) {
                try Self.write(
                    Data($0),
                    to: client,
                    maximumChunkSize: .max
                )
            }
        }
    }

    private static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count + 1 <= capacity else {
            throw FakeUnixRuntimeServerError.pathTooLong
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.initializeMemory(as: UInt8.self, repeating: 0)
            $0.copyBytes(from: bytes)
        }
        return address
    }

    private static func readFrame(from descriptor: Int32) throws -> Data {
        let header = try read(byteCount: 4, from: descriptor)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(64 * 1_024) else {
            throw FakeUnixRuntimeServerError.invalidRequest
        }
        return try read(byteCount: Int(length), from: descriptor)
    }

    private static func read(
        byteCount: Int,
        from descriptor: Int32
    ) throws -> Data {
        var data = Data(count: byteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < byteCount {
                let count = Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    min(3, byteCount - offset)
                )
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    throw FakeUnixRuntimeServerError.invalidRequest
                } else if errno != EINTR {
                    throw FakeUnixRuntimeServerError.systemCall("read", errno)
                }
            }
        }
        return data
    }

    private static func write(
        _ data: Data,
        to descriptor: Int32,
        maximumChunkSize: Int,
        delayMicroseconds: useconds_t = 0
    ) throws {
        var enabled: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let requested = min(
                    maximumChunkSize,
                    buffer.count - offset
                )
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    requested
                )
                if count > 0 {
                    offset += count
                    let delay = delayMicroseconds > 0
                        ? delayMicroseconds
                        : (maximumChunkSize == 1 ? 500 : 0)
                    if delay > 0 {
                        usleep(delay)
                    }
                } else if count == 0 {
                    throw FakeUnixRuntimeServerError.systemCall("write", EIO)
                } else if errno != EINTR {
                    throw FakeUnixRuntimeServerError.systemCall("write", errno)
                }
            }
        }
    }
}

private enum FakeUnixRuntimeServerError: Error {
    case systemCall(String, Int32)
    case invalidRequest
    case pathTooLong
    case timedOut
}
