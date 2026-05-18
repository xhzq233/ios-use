import XCTest
import Darwin
@testable import IOSUseCLI
@preconcurrency import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

final class NSLogServiceTests: XCTestCase {
    func testServerOptionsKeepFixedPortAndPreserveAllowedFlowFields() {
        let options = NSLoggerServerOptions(name: "ios-use-test", publishBonjour: false, maxBufferSize: 3)

        XCTAssertEqual(options.port, 50_000)
        XCTAssertTrue(options.useSSL)
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

    func testRegexFlagsMatchOSLogSemanticsAndRejectInvalidFlags() throws {
        XCTAssertTrue(try NSLogService.matches("Alpha\nBeta", pattern: "alpha", flags: "i"))
        XCTAssertTrue(try NSLogService.matches("Alpha\nBeta", pattern: "^Beta", flags: "m"))
        XCTAssertTrue(try NSLogService.matches("Alpha\nBeta", pattern: "Alpha.*Beta", flags: "s"))

        XCTAssertThrowsError(try NSLogService.matches("ready", pattern: "ready", flags: "z")) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid regex flag"))
        }
    }

    func testServerGrepCursorSurvivesBufferEviction() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-nslog-\(UUID().uuidString)").path
        ])
        let server = try NSLoggerServer(options: NSLoggerServerOptions(publishBonjour: false, maxBufferSize: 2), paths: paths)
        let regex = try NSRegularExpression(pattern: "new")

        server.ingestForTesting(makeMessage(parts: [(7, 0, stringData("old one"))]))
        server.ingestForTesting(makeMessage(parts: [(7, 0, stringData("old two"))]))
        let first = server.grep(regex: regex, from: 0)
        XCTAssertTrue(first.matches.isEmpty)

        server.ingestForTesting(makeMessage(parts: [(7, 0, stringData("new three"))]))
        let second = server.grep(regex: regex, from: first.nextIndex)

        XCTAssertEqual(second.matches.count, 1)
        XCTAssertTrue(second.matches[0].contains("new three"))
    }

    func testServerAcceptsRealTLSClientFrameWithoutKeychain() throws {
        guard isPortAvailable(50_000) else {
            throw XCTSkip("NSLogger fixed port 50000 is already in use")
        }
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-nslog-tls-\(UUID().uuidString)").path
        ])
        let server = try NSLoggerServer(options: NSLoggerServerOptions(publishBonjour: false), paths: paths)
        try server.start()
        defer { server.stop() }

        try sendTLSFrame(makeMessage(parts: [(7, 0, stringData("TLS ready"))]), port: 50_000)

        let deadline = Date().addingTimeInterval(5)
        while server.logCount == 0, Date() < deadline {
            usleep(50_000)
        }

        XCTAssertEqual(server.clientCount, 1)
        XCTAssertEqual(try server.grep(pattern: "TLS ready").count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(paths.root)/runtime/nslogger-selfsigned.key"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(paths.root)/runtime/nslogger-selfsigned.crt"))
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

    private func sendTLSFrame(_ data: Data, port: UInt16) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .none
        let sslContext = try NIOSSLContext(configuration: configuration)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                do {
                    let handler = try NIOSSLClientHandler(context: sslContext, serverHostname: "localhost")
                    return channel.pipeline.addHandler(handler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let channel = try bootstrap.connect(host: "127.0.0.1", port: Int(port)).wait()
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try channel.writeAndFlush(buffer).wait()
        usleep(100_000)
        try channel.close().wait()
    }
}
