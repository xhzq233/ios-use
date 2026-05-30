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

    func testAcceptLoopWaitsForPreviousClientDuringHandoff() throws {
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
        Darwin.shutdown(firstFD!, SHUT_RDWR)
        Darwin.close(firstFD!)
        firstFD = nil

        XCTAssertEqual(sem.wait(timeout: .now() + .seconds(2)), .success)
        lock.lock()
        let result = secondResult
        lock.unlock()
        switch result {
        case .success(let response):
            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.error.contains("unknown command"))
        case .failure(let error):
            XCTFail("second client should be accepted after handoff, got \(error)")
        case nil:
            XCTFail("second client did not report a result")
        }
    }

    func testPendingInitialConnectionIsReplacedByNextClient() throws {
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
    }

    func testPartialInitialFrameIsNotReplacedByNextClient() throws {
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
        if case .success(let response) = result {
            XCTFail("second client should not replace a partial first frame, got \(response)")
        }

        try Self.writeAll(fd: firstFD, data: firstRequest.dropFirst(1))
        let firstResponse = try Self.readResponse(fd: firstFD)
        XCTAssertFalse(firstResponse.ok)
        XCTAssertTrue(firstResponse.error.contains("unknown command"))
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
