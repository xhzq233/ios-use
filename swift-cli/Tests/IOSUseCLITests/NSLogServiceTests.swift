import XCTest
import Darwin
import IOSUseCLI

final class NSLogServiceTests: XCTestCase {
    func testServerOptionsKeepFixedPortAndPreserveAllowedFlowFields() {
        let options = NSLoggerServerOptions(name: "ios-use-test", publishBonjour: false, maxBufferSize: 3)

        XCTAssertEqual(options.port, 50_000)
        XCTAssertEqual(options.name, "ios-use-test")
        XCTAssertFalse(options.publishBonjour)
        XCTAssertEqual(options.maxBufferSize, 3)
    }

    func testParseAndFormatLogMessage() {
        let data = makeMessage(parts: [
            (0, 3, int32Data(0)),
            (5, 0, stringData("driver")),
            (6, 3, int32Data(2)),
            (7, 0, stringData("ready")),
            (11, 0, stringData("File.swift")),
            (12, 3, int32Data(42)),
            (13, 0, stringData("boot"))
        ])

        let parsed = NSLogService.parseMessage(data)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.consumed, data.count)

        let formatted = NSLogService.formatLogEntry(parsed?.parts ?? [:])
        XCTAssertTrue(formatted.contains("[driver]"))
        XCTAssertTrue(formatted.contains("L2"))
        XCTAssertTrue(formatted.contains("File.swift:42"))
        XCTAssertTrue(formatted.contains("boot()"))
        XCTAssertTrue(formatted.contains("ready"))
    }

    func testParseMessageWaitsForCompleteFrame() {
        let data = makeMessage(parts: [(7, 0, stringData("ready"))])
        let partial = data.prefix(data.count - 1)

        XCTAssertNil(NSLogService.parseMessage(Data(partial)))
    }

    func testServerBuffersGrepsAndClearsWithoutStartingSocket() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-nslog-\(UUID().uuidString)").path
        ])
        let server = try NSLoggerServer(paths: paths)

        server.ingestForTesting(makeMessage(parts: [(7, 0, stringData("Alpha ready"))]))
        server.ingestForTesting(makeMessage(parts: [(7, 0, stringData("Beta idle"))]))

        XCTAssertEqual(server.clientCount, 1)
        XCTAssertEqual(server.logCount, 2)
        XCTAssertEqual(try server.grep(pattern: "ready", flags: "i").count, 1)

        server.clear()
        XCTAssertEqual(server.logCount, 0)
    }

    func testServerAcceptsRealPlainTCPClientFrame() throws {
        guard isPortAvailable(50_000) else {
            throw XCTSkip("NSLogger fixed port 50000 is already in use")
        }
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-nslog-tcp-\(UUID().uuidString)").path
        ])
        let server = try NSLoggerServer(options: NSLoggerServerOptions(publishBonjour: false), paths: paths)
        try server.start()
        defer { server.stop() }

        let fd = try connectLocalhost(port: 50_000)
        defer { Darwin.close(fd) }
        try writeAll(fd: fd, data: makeMessage(parts: [(7, 0, stringData("TCP ready"))]))

        let deadline = Date().addingTimeInterval(5)
        while server.logCount == 0, Date() < deadline {
            usleep(50_000)
        }

        XCTAssertEqual(server.clientCount, 1)
        XCTAssertEqual(try server.grep(pattern: "TCP ready").count, 1)
    }

    private func makeMessage(parts: [(UInt8, UInt8, Data)]) -> Data {
        var body = Data()
        body.append(UInt8((parts.count >> 8) & 0xff))
        body.append(UInt8(parts.count & 0xff))
        for part in parts {
            body.append(part.0)
            body.append(part.1)
            body.append(part.2)
        }
        var data = Data()
        data.append(uint32Data(UInt32(body.count)))
        data.append(body)
        return data
    }

    private func stringData(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return uint32Data(UInt32(bytes.count)) + bytes
    }

    private func int32Data(_ value: Int32) -> Data {
        uint32Data(UInt32(bitPattern: value))
    }

    private func uint32Data(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ])
    }

    private func isPortAvailable(_ port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private func connectLocalhost(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
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

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno != EINTR {
                    throw NSError(domain: "write", code: Int(errno))
                }
            }
        }
    }
}
