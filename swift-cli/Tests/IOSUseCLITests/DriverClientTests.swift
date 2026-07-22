import Darwin
import Foundation
import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class DriverClientTests: XCTestCase {
    func testClientReusesConnectionWithinInstance() throws {
        let server = try FakeDriverServer(responseCount: 2)
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))
        defer { client.close() }

        _ = try client.dom(raw: false, fresh: false)
        _ = try client.dom(raw: true, fresh: true)

        XCTAssertEqual(server.acceptCount, 1)
        XCTAssertEqual(server.requestCommands, ["dom", "dom"])
    }

    func testClientKeepsConnectionAfterNonFatalDriverError() throws {
        let fory = ForyRegistry.create()
        let okPayload = try fory.serialize(ForyDomPayload(app: "fake"))
        let errorPayload = try fory.serialize(ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.elementNotFound,
            phase: IOSUseErrorPhase.lookup,
            retryable: true,
            target: ForyTarget(label: "missing")
        ))
        let server = try FakeDriverServer(responses: [
            ForyResponseFrame(ok: false, error: "driver rejected request", payload: errorPayload),
            ForyResponseFrame(ok: true, payload: okPayload),
        ])
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))
        defer { client.close() }

        XCTAssertThrowsError(try client.dom(raw: false, fresh: false)) { error in
            XCTAssertTrue(String(describing: error).contains("driver rejected request"))
        }
        _ = try client.dom(raw: true, fresh: true)

        XCTAssertEqual(server.acceptCount, 1)
        XCTAssertEqual(server.requestCommands, ["dom", "dom"])
    }

    func testClientClosesConnectionAfterFatalDriverError() throws {
        let fory = ForyRegistry.create()
        let okPayload = try fory.serialize(ForyDomPayload(app: "fake"))
        let errorPayload = try fory.serialize(ForyErrorPayload(
            category: IOSUseErrorCategory.timeout,
            code: IOSUseErrorCode.driverWatchdogTimeout,
            phase: IOSUseErrorPhase.dispatch,
            fatal: true
        ))
        let server = try FakeDriverServer(responses: [
            ForyResponseFrame(ok: false, error: "main thread stuck", payload: errorPayload),
            ForyResponseFrame(ok: true, payload: okPayload),
        ])
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))
        defer { client.close() }

        XCTAssertThrowsError(try client.dom(raw: false, fresh: false)) { error in
            XCTAssertTrue(String(describing: error).contains("[driver_watchdog_timeout] main thread stuck"))
        }
        _ = try client.dom(raw: true, fresh: true)

        XCTAssertEqual(server.acceptCount, 2)
        XCTAssertEqual(server.requestCommands, ["dom", "dom"])
    }

    func testClientRejectsLegacyMessageOnlyDriverError() throws {
        let server = try FakeDriverServer(responses: [
            ForyResponseFrame(ok: false, error: "legacy driver error", payload: Data()),
        ])
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))
        defer { client.close() }

        XCTAssertThrowsError(try client.dom(raw: false, fresh: false)) { error in
            XCTAssertTrue(String(describing: error).contains("invalid driver error payload"))
            XCTAssertTrue(String(describing: error).contains("empty payload"))
        }

        XCTAssertTrue(server.waitForDisconnect(timeout: 1.0))
    }

    func testClientSerializesWaitForLookupTargetFields() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyWaitForPayload())
        let server = try FakeDriverServer(responses: [ForyResponseFrame(ok: true, payload: payload)])
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))
        defer { client.close() }

        _ = try client.waitFor(label: "General", timeout: 1.5, traits: "Cell", cindex: -1)

        let request = try XCTUnwrap(server.requestFrames.first)
        XCTAssertEqual(request.command, DriverCommand.waitFor.rawValue)
        let args = try fory.deserialize(request.payload, as: ForyWaitForArgs.self)
        XCTAssertEqual(args.target.label, "General")
        XCTAssertEqual(args.target.traits, "Cell")
        XCTAssertEqual(args.target.cindex, -1)
        XCTAssertEqual(args.timeout, 1.5)
        XCTAssertFalse(args.gone)
    }

    func testClientSerializesWaitForGone() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyWaitForPayload())
        let server = try FakeDriverServer(responses: [ForyResponseFrame(ok: true, payload: payload)])
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))
        defer { client.close() }

        _ = try client.waitFor(label: "Loading", timeout: 2, traits: nil, cindex: nil, gone: true)

        let request = try XCTUnwrap(server.requestFrames.first)
        let args = try fory.deserialize(request.payload, as: ForyWaitForArgs.self)
        XCTAssertEqual(args.target.label, "Loading")
        XCTAssertEqual(args.timeout, 2)
        XCTAssertTrue(args.gone)
        XCTAssertEqual(args.matchMode, IOSUseWaitForMatchMode.standard.rawValue)
    }

    func testClientSerializesWaitForRegexAndUsesSharedLongWaitBudgets() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyWaitForPayload())
        let server = try FakeDriverServer(responses: [ForyResponseFrame(ok: true, payload: payload)])
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))
        defer { client.close() }

        _ = try client.waitFor(
            label: #"Loading \d+%"#,
            timeout: 55,
            traits: nil,
            cindex: nil,
            gone: true,
            matchMode: .regex
        )

        let request = try XCTUnwrap(server.requestFrames.first)
        let args = try fory.deserialize(request.payload, as: ForyWaitForArgs.self)
        XCTAssertEqual(args.timeout, 55)
        XCTAssertEqual(args.matchMode, IOSUseWaitForMatchMode.regex.rawValue)
        XCTAssertEqual(IOSUseProtocol.waitForWatchdogTimeoutSeconds(args.timeout), 65)
        XCTAssertEqual(IOSUseProtocol.waitForSocketReadTimeoutSeconds(args.timeout), 67)
        XCTAssertEqual(IOSUseProtocol.waitForWatchdogTimeoutSeconds(0), 20)
        XCTAssertEqual(IOSUseProtocol.waitForSocketReadTimeoutSeconds(0), 22)
    }

    func testClientSerializesDomWaitQuiescence() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyDomPayload())
        let server = try FakeDriverServer(responses: [ForyResponseFrame(ok: true, payload: payload)])
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))
        defer { client.close() }

        _ = try client.dom(raw: false, fresh: true, waitQuiescence: true)

        let request = try XCTUnwrap(server.requestFrames.first)
        XCTAssertEqual(request.command, DriverCommand.dom.rawValue)
        let args = try fory.deserialize(request.payload, as: ForyDomArgs.self)
        XCTAssertFalse(args.raw)
        XCTAssertTrue(args.fresh)
        XCTAssertTrue(args.waitQuiescence)
    }

    func testClientWritesCommandLogToCLILog() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyDomPayload(app: "fake"))
        let server = try FakeDriverServer(responses: [
            ForyResponseFrame(ok: true, payload: payload),
            ForyResponseFrame(ok: true, payload: payload),
        ])
        defer { server.stop() }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-cli-log-\(UUID().uuidString)")
        let logPath = tempRoot.appendingPathComponent("logs/cli.log").path
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let client = DriverClient(port: UInt16(server.port), cliLogPath: logPath)
        defer { client.close() }

        _ = try client.dom(raw: false, fresh: true)
        _ = try client.dom(raw: true, fresh: false)
        client.close()

        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("[cli-driver-connection] id="))
        XCTAssertTrue(log.contains("event=open"))
        XCTAssertTrue(log.contains("event=close"))
        XCTAssertTrue(log.contains("[cli-command] command=dom ok=true"))
        XCTAssertTrue(log.contains("command=dom ok=true connectionId="))
        XCTAssertTrue(log.contains("requestBytes="))
        XCTAssertTrue(log.contains("responseBytes="))
        let commandLines = log.split(separator: "\n").filter {
            $0.contains("[cli-command] command=dom ok=true connectionId=")
        }
        XCTAssertEqual(commandLines.count, 2)
        let connectionIDs = Set(commandLines.compactMap { line -> String? in
            guard let range = line.range(of: "connectionId=") else { return nil }
            return line[range.upperBound...].split(separator: " ").first.map(String.init)
        })
        XCTAssertEqual(connectionIDs.count, 1)
        if let connectionID = connectionIDs.first {
            XCTAssertTrue(log.contains("[cli-driver-connection] id=\(connectionID) event=open"))
            XCTAssertTrue(log.contains("[cli-driver-connection] id=\(connectionID) event=close"))
        }
        XCTAssertFalse(log.contains("[driver-perf]"))
        XCTAssertFalse(log.contains("[driver-response]"))
    }

    func testExplicitCloseSignalsEOFToServerPromptly() throws {
        let server = try FakeDriverServer(responseCount: 2)
        defer { server.stop() }
        let client = DriverClient(port: UInt16(server.port))

        _ = try client.dom(raw: false, fresh: false)

        XCTAssertFalse(server.waitForDisconnect(timeout: 0.1))
        client.close()

        XCTAssertTrue(server.waitForDisconnect(timeout: 1.0))
    }

    func testRealDeviceConnectDoesNotRetryBeforeSendingRequest() throws {
        var attempts = 0
        DriverClient.usbmuxConnectorForTesting = { _, _ in
            attempts += 1
            throw UsbmuxError.connectFailed(response: "driver not listening yet")
        }
        addTeardownBlock {
            DriverClient.usbmuxConnectorForTesting = nil
        }

        let client = DriverClient(udid: "REAL-CMD", deviceType: "real")
        defer { client.close() }

        XCTAssertThrowsError(try client.dom(raw: false, fresh: false)) { error in
            XCTAssertTrue(String(describing: error).contains("driver not listening yet"))
        }

        XCTAssertEqual(attempts, 1)
    }
}

final class FakeDriverServer {
    let port: Int
    private let listenFD: Int32
    private let responses: [ForyResponseFrame]
    private let lock = NSLock()
    private var thread: Thread?
    private var stopped = false
    private var accepted = 0
    private var nextResponseIndex = 0
    private var commands: [String] = []
    private var requests: [ForyRequestFrame] = []
    private let fory = ForyRegistry.create()
    private let disconnectSem = DispatchSemaphore(value: 0)

    init(responseCount: Int) throws {
        let payload = (try? ForyRegistry.create().serialize(ForyDomPayload(app: "fake"))) ?? Data()
        self.responses = (0..<responseCount).map { _ in ForyResponseFrame(ok: true, payload: payload) }
        let fd = try Self.makeListenSocket()
        self.listenFD = fd.listenFD
        self.port = fd.port
        let worker = Thread { [weak self] in self?.serve() }
        thread = worker
        worker.start()
    }

    init(responses: [ForyResponseFrame]) throws {
        self.responses = responses
        let fd = try Self.makeListenSocket()
        self.listenFD = fd.listenFD
        self.port = fd.port
        let worker = Thread { [weak self] in self?.serve() }
        thread = worker
        worker.start()
    }

    private static func makeListenSocket() throws -> (listenFD: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIParseError.invalidValue("socket failed: \(errno)")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("bind failed: \(errno)")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("getsockname failed: \(errno)")
        }
        guard listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("listen failed: \(errno)")
        }
        return (fd, Int(UInt16(bigEndian: bound.sin_port)))
    }

    var acceptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    var requestCommands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    var requestFrames: [ForyRequestFrame] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    func waitForDisconnect(timeout: TimeInterval) -> Bool {
        disconnectSem.wait(timeout: .now() + timeout) == .success
    }

    private func serve() {
        while true {
            lock.lock()
            let shouldStop = stopped || nextResponseIndex >= responses.count
            lock.unlock()
            if shouldStop { return }

            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            lock.lock()
            accepted += 1
            lock.unlock()
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer {
            Darwin.close(clientFD)
            disconnectSem.signal()
        }
        while true {
            lock.lock()
            let shouldStop = stopped || nextResponseIndex >= responses.count
            lock.unlock()
            if shouldStop { return }

            guard let requestData = try? readFrame(fd: clientFD),
                  let request = try? fory.deserialize(requestData, as: ForyRequestFrame.self) else {
                return
            }
            lock.lock()
            commands.append(request.command)
            requests.append(request)
            let response = responses[nextResponseIndex]
            nextResponseIndex += 1
            lock.unlock()
            guard let frame = try? fory.serialize(response) else { return }
            try? writeFrame(fd: clientFD, data: frame)
        }
    }

    private func readFrame(fd: Int32) throws -> Data {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        try readExact(fd: fd, buffer: &lengthBytes)
        let length = Int((UInt32(lengthBytes[0]) << 24) | (UInt32(lengthBytes[1]) << 16) | (UInt32(lengthBytes[2]) << 8) | UInt32(lengthBytes[3]))
        var data = [UInt8](repeating: 0, count: length)
        try readExact(fd: fd, buffer: &data)
        return Data(data)
    }

    private func writeFrame(fd: Int32, data: Data) throws {
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, 4)
        }
        data.withUnsafeBytes { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, data.count)
        }
    }

    private func readExact(fd: Int32, buffer: inout [UInt8]) throws {
        var offset = 0
        while offset < buffer.count {
            let remaining = buffer.count - offset
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if n <= 0 { throw CLIParseError.invalidValue("read failed") }
            offset += n
        }
    }
}
