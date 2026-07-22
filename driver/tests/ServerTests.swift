import Darwin
import Foundation
import XCTest

final class ServerTests: XCTestCase {
    override func tearDown() {
        DriverServer.shared.stop()
        super.tearDown()
    }

    func testStop_DoesNotDeadlockWhenServerIsIdle() {
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            DriverServer.shared.stop()
            sem.signal()
        }

        XCTAssertEqual(sem.wait(timeout: .now() + .seconds(1)), .success)
    }

    func testWaitForInvocationDerivesWatchdogFromRequestedDeadline() throws {
        let args = ForyWaitForArgs(target: ForyTarget(label: "Loading"), timeout: 55, gone: true)
        let payload = try ForyRegistry.create().serialize(args)
        let invocation = try CommandInvocation(name: .waitFor, payload: payload, codec: Codec.Context())

        XCTAssertEqual(invocation.watchdogTimeoutSeconds, 65)
        XCTAssertEqual(IOSUseProtocol.waitForSocketReadTimeoutSeconds(args.timeout), 67)
    }

    func testWaitForInvocationBoundsMalformedWatchdogDeadline() throws {
        let args = ForyWaitForArgs(target: ForyTarget(label: "Loading"), timeout: .infinity)
        let payload = try ForyRegistry.create().serialize(args)
        let invocation = try CommandInvocation(name: .waitFor, payload: payload, codec: Codec.Context())

        XCTAssertEqual(invocation.watchdogTimeoutSeconds, 310)
        XCTAssertEqual(IOSUseProtocol.waitForSocketReadTimeoutSeconds(args.timeout), 312)
    }

    func testWaitAppForegroundInvocationDerivesWatchdogFromRequestedDeadline() throws {
        let args = ForyWaitAppForegroundArgs(
            expectedBundleId: "com.example.app",
            timeout: 12,
            returnDom: true
        )
        let payload = try ForyRegistry.create().serialize(args)
        let invocation = try CommandInvocation(
            name: .waitAppForeground,
            payload: payload,
            codec: Codec.Context()
        )

        XCTAssertEqual(invocation.watchdogTimeoutSeconds, 22)
        XCTAssertEqual(IOSUseProtocol.appForegroundSocketReadTimeoutSeconds(args.timeout), 24)
    }

    func testWaitAppForegroundInvocationBoundsMalformedWatchdogDeadline() throws {
        let args = ForyWaitAppForegroundArgs(timeout: .infinity)
        let payload = try ForyRegistry.create().serialize(args)
        let invocation = try CommandInvocation(
            name: .waitAppForeground,
            payload: payload,
            codec: Codec.Context()
        )

        XCTAssertEqual(invocation.watchdogTimeoutSeconds, 310)
        XCTAssertEqual(IOSUseProtocol.appForegroundSocketReadTimeoutSeconds(args.timeout), 312)
    }

    func testSecondConnectionIsAcceptedWhileFirstConnectionStaysOpen() throws {
        DriverServer.shared.stop()
        let port = try Self.freePort()
        try DriverServer.shared.start(port: port)

        var firstFD: Int32? = try Self.connect(port: port)
        defer {
            if let firstFD {
                Darwin.close(firstFD)
            }
        }
        let firstResponse = try Self.sendRequestAndReadResponse(fd: firstFD!, command: "unitUnknownFirst")
        XCTAssertFalse(firstResponse.ok)
        XCTAssertTrue(firstResponse.error.contains("unknown command"))

        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var secondResult: Result<ForyResponseFrame, Error>?
        DispatchQueue.global().async {
            do {
                let fd = try Self.connect(port: port)
                defer { Darwin.close(fd) }
                let response = try Self.sendRequestAndReadResponse(fd: fd, command: "unitUnknownSecond")
                lock.lock()
                secondResult = .success(response)
                lock.unlock()
            } catch {
                lock.lock()
                secondResult = .failure(error)
                lock.unlock()
            }
            sem.signal()
        }

        usleep(50_000)
        XCTAssertEqual(sem.wait(timeout: .now() + .seconds(2)), .success)
        lock.lock()
        let result = secondResult
        lock.unlock()
        switch result {
        case .success(let response):
            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.error.contains("unknown command"))
        case .failure(let error):
            XCTFail("second client should be accepted while first remains open, got \(error)")
        case nil:
            XCTFail("second client did not report a result")
        }

        let thirdOnFirst = try Self.sendRequestAndReadResponse(fd: firstFD!, command: "unitUnknownFirstStillOpen")
        XCTAssertFalse(thirdOnFirst.ok)
        XCTAssertTrue(thirdOnFirst.error.contains("unknown command"))
    }

    func testSameConnectionHandlesMultipleRequestResponseCycles() throws {
        DriverServer.shared.stop()
        let port = try Self.freePort()
        try DriverServer.shared.start(port: port)

        let fd = try Self.connect(port: port)
        defer { Darwin.close(fd) }

        let first = try Self.sendRequestAndReadResponse(fd: fd, command: "unitUnknownFirst")
        let second = try Self.sendRequestAndReadResponse(fd: fd, command: "unitUnknownSecond")

        XCTAssertFalse(first.ok)
        XCTAssertTrue(first.error.contains("unknown command"))
        let firstPayload = try Self.errorPayload(first)
        XCTAssertEqual(firstPayload.category, IOSUseErrorCategory.protocolFailure)
        XCTAssertEqual(firstPayload.code, IOSUseErrorCode.unknownCommand)
        XCTAssertEqual(firstPayload.phase, IOSUseErrorPhase.validation)
        XCTAssertFalse(firstPayload.fatal)
        XCTAssertFalse(second.ok)
        XCTAssertTrue(second.error.contains("unknown command"))
    }

    func testPendingEmptyConnectionDoesNotBlockNextClient() throws {
        DriverServer.shared.stop()
        let port = try Self.freePort()
        try DriverServer.shared.start(port: port)

        let emptyFD = try Self.connect(port: port)
        defer { Darwin.close(emptyFD) }
        usleep(50_000)

        let commandFD = try Self.connect(port: port)
        defer { Darwin.close(commandFD) }
        let response = try Self.sendRequestAndReadResponse(fd: commandFD, command: "unitUnknownAfterPendingEmpty")

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error.contains("unknown command"))

        let pendingResponse = try Self.sendRequestAndReadResponse(fd: emptyFD, command: "unitUnknownPendingStillOpen")
        XCTAssertFalse(pendingResponse.ok)
        XCTAssertTrue(pendingResponse.error.contains("unknown command"))
    }

    func testPartialInitialFrameDoesNotBlockNextClient() throws {
        DriverServer.shared.stop()
        let port = try Self.freePort()
        try DriverServer.shared.start(port: port)

        let firstFD = try Self.connect(port: port)
        defer { Darwin.close(firstFD) }

        let firstRequest = try Self.serializedRequest(command: "unitUnknownPartialFirst")
        try Self.writeAll(fd: firstFD, data: firstRequest.prefix(1))
        usleep(50_000)

        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var secondResult: Result<ForyResponseFrame, Error>?
        DispatchQueue.global().async {
            do {
                let fd = try Self.connect(port: port)
                defer { Darwin.close(fd) }
                let response = try Self.sendRequestAndReadResponse(fd: fd, command: "unitUnknownSecondAfterPartial")
                lock.lock()
                secondResult = .success(response)
                lock.unlock()
            } catch {
                lock.lock()
                secondResult = .failure(error)
                lock.unlock()
            }
            sem.signal()
        }

        XCTAssertEqual(sem.wait(timeout: .now() + .seconds(2)), .success)
        lock.lock()
        let result = secondResult
        lock.unlock()
        switch result {
        case .success(let response):
            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.error.contains("unknown command"))
        case .failure(let error):
            XCTFail("second client should not be blocked by a partial first frame, got \(error)")
        case nil:
            XCTFail("second client did not report a result")
        }

        try Self.writeAll(fd: firstFD, data: firstRequest.dropFirst(1))
        let firstResponse = try Self.readResponse(fd: firstFD)
        XCTAssertFalse(firstResponse.ok)
        XCTAssertTrue(firstResponse.error.contains("unknown command"))
    }

    func testConcurrentKnownCommandsAreSerializedOnMainThreadInQueueOrder() throws {
        DriverServer.shared.stop()
        let port = try Self.freePort()

        let lock = NSLock()
        var activeCommands = 0
        var maxActiveCommands = 0
        var mainThreadExecutions = 0
        var startOrder: [String] = []
        let firstStarted = DispatchSemaphore(value: 0)

        DriverServer.dispatchForyForTesting = { command in
            XCTAssertTrue(Thread.isMainThread)
            lock.lock()
            activeCommands += 1
            maxActiveCommands = max(maxActiveCommands, activeCommands)
            mainThreadExecutions += 1
            startOrder.append(command.rawValue)
            lock.unlock()

            if command == .home {
                firstStarted.signal()
                usleep(100_000)
            }

            lock.lock()
            activeCommands -= 1
            lock.unlock()
            return Codec.foryOK()
        }
        defer { DriverServer.dispatchForyForTesting = nil }

        try DriverServer.shared.start(port: port)

        let done = expectation(description: "concurrent known commands complete")
        done.expectedFulfillmentCount = 2
        let resultLock = NSLock()
        var responses: [ForyResponseFrame] = []
        var errors: [Error] = []

        DispatchQueue.global().async {
            do {
                let fd = try Self.connect(port: port)
                defer { Darwin.close(fd) }
                let response = try Self.sendRequestAndReadResponse(fd: fd, command: Command.home.rawValue)
                resultLock.lock()
                responses.append(response)
                resultLock.unlock()
            } catch {
                resultLock.lock()
                errors.append(error)
                resultLock.unlock()
            }
            done.fulfill()
        }

        DispatchQueue.global().async {
            guard firstStarted.wait(timeout: .now() + .seconds(1)) == .success else {
                resultLock.lock()
                errors.append(NSError(domain: "ServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "first command did not start"]))
                resultLock.unlock()
                done.fulfill()
                return
            }
            do {
                let fd = try Self.connect(port: port)
                defer { Darwin.close(fd) }
                let response = try Self.sendRequestAndReadResponse(fd: fd, command: Command.screenshot.rawValue)
                resultLock.lock()
                responses.append(response)
                resultLock.unlock()
            } catch {
                resultLock.lock()
                errors.append(error)
                resultLock.unlock()
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 2)

        resultLock.lock()
        let capturedResponses = responses
        let capturedErrors = errors
        resultLock.unlock()
        XCTAssertTrue(capturedErrors.isEmpty, "unexpected errors: \(capturedErrors)")
        XCTAssertEqual(capturedResponses.count, 2)
        XCTAssertTrue(capturedResponses.allSatisfy(\.ok))

        lock.lock()
        let capturedMaxActiveCommands = maxActiveCommands
        let capturedMainThreadExecutions = mainThreadExecutions
        let capturedStartOrder = startOrder
        lock.unlock()
        XCTAssertEqual(capturedMainThreadExecutions, 2)
        XCTAssertEqual(capturedMaxActiveCommands, 1)
        XCTAssertEqual(capturedStartOrder, [Command.home.rawValue, Command.screenshot.rawValue])
    }

    private static func freePort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw NSError(domain: "bind", code: Int(errno)) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw NSError(domain: "getsockname", code: Int(errno)) }
        return UInt16(bigEndian: bound.sin_port)
    }

    private static func connect(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: "connect", code: Int(err))
        }
        return fd
    }

    private static func sendRequestAndReadResponse(fd: Int32, command: String) throws -> ForyResponseFrame {
        try writeAll(fd: fd, data: try serializedRequest(command: command))
        return try readResponse(fd: fd)
    }

    private static func serializedRequest(command: String) throws -> Data {
        let fory = createFory()
        let request = ForyRequestFrame(command: command, payload: Data())
        let body = try fory.serialize(request)
        var frame = Data()
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    private static func readResponse(fd: Int32) throws -> ForyResponseFrame {
        let fory = createFory()
        return try fory.deserialize(readLengthPrefixedData(fd), as: ForyResponseFrame.self)
    }

    private static func errorPayload(_ response: ForyResponseFrame) throws -> ForyErrorPayload {
        try createFory().deserialize(response.payload, as: ForyErrorPayload.self)
    }

    private static func writeAll<T: DataProtocol>(fd: Int32, data: T) throws {
        let bytes = Array(data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuffer in
                Darwin.write(fd, rawBuffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: "write", code: Int(errno))
            }
            if written == 0 {
                throw NSError(domain: "write", code: 0)
            }
            offset += written
        }
    }

    private static func readLengthPrefixedData(_ fd: Int32) throws -> Data {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        try readExact(fd, into: &lengthBytes)
        let length = Int((UInt32(lengthBytes[0]) << 24) | (UInt32(lengthBytes[1]) << 16) | (UInt32(lengthBytes[2]) << 8) | UInt32(lengthBytes[3]))
        var data = [UInt8](repeating: 0, count: length)
        try readExact(fd, into: &data)
        return Data(data)
    }

    private static func readExact(_ fd: Int32, into buffer: inout [UInt8]) throws {
        var offset = 0
        while offset < buffer.count {
            let remaining = buffer.count - offset
            let n = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress!.advanced(by: offset), remaining)
            }
            if n <= 0 { throw NSError(domain: "read", code: Int(errno)) }
            offset += n
        }
    }
}
