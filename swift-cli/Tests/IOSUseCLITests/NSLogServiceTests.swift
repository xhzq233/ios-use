import XCTest
import Darwin
@testable import IOSUseDaemonRuntime
@preconcurrency import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

final class NSLogServiceTests: XCTestCase {
    override func tearDown() {
        NSLogService.processCommandOverrideForTesting = nil
        NSLogService.processAliveOverrideForTesting = nil
        NSLogService.killOverrideForTesting = nil
        NSLogService.serverOptionsOverrideForTesting = nil
        super.tearDown()
    }

    func testServerOptionsUseRandomPortAndPreserveAllowedFlowFields() {
        let options = NSLoggerServerOptions(name: "ios-use-test", publishBonjour: false, maxBufferSize: 3)

        XCTAssertEqual(options.port, 0)
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
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-nslog-tls-\(UUID().uuidString)").path
        ])
        let server = try NSLoggerServer(options: NSLoggerServerOptions(publishBonjour: false), paths: paths)
        try server.start()
        defer { server.stop() }

        XCTAssertNotEqual(server.port, 0)
        XCTAssertNotEqual(server.port, 50_000)

        try sendTLSFrame(makeMessage(parts: [(7, 0, stringData("TLS ready"))]), port: UInt16(server.port))

        let deadline = Date().addingTimeInterval(5)
        while server.logCount == 0, Date() < deadline {
            usleep(50_000)
        }

        XCTAssertEqual(server.clientCount, 1)
        XCTAssertEqual(try server.grep(pattern: "TLS ready").count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(paths.root)/runtime/nslogger-selfsigned.key"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(paths.root)/runtime/nslogger-selfsigned.crt"))
    }

    func testLockRecordsActualRandomPortAndBonjourPid() throws {
        let paths = makePaths()
        let server = try NSLoggerServer(options: NSLoggerServerOptions(name: "unit-nslog", publishBonjour: false), paths: paths)
        try server.start()
        defer { server.stop() }

        try NSLogService.writeLock(paths: paths, server: server, mode: "flow")
        let data = try Data(contentsOf: URL(fileURLWithPath: paths.nslogLock))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(json["port"] as? Int, server.port)
        XCTAssertEqual(json["iosUseHome"] as? String, paths.root)
        XCTAssertEqual(json["mode"] as? String, "flow")
        XCTAssertNil(json["bonjourPid"])
    }

    func testAcquireForegroundOwnershipRemovesStaleLock() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true)
        try #"{"pid":424242,"port":50000,"startedAt":"old","iosUseHome":"\#(paths.root)","mode":"cli"}"#
            .write(toFile: paths.nslogLock, atomically: true, encoding: .utf8)
        NSLogService.processAliveOverrideForTesting = { _ in false }

        try NSLogService.acquireForegroundOwnership(paths: paths, mode: "cli")

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.nslogLock))
    }

    func testAcquireForegroundOwnershipTerminatesOldIOSUseAndBonjourProcesses() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true)
        try #"{"pid":1111,"bonjourPid":2222,"port":51723,"name":"unit","startedAt":"old","iosUseHome":"\#(paths.root)","mode":"cli"}"#
            .write(toFile: paths.nslogLock, atomically: true, encoding: .utf8)
        var alive: Set<Int32> = [1111, 2222]
        var signals: [(Int32, Int32)] = []
        NSLogService.processAliveOverrideForTesting = { alive.contains($0) }
        NSLogService.processCommandOverrideForTesting = { pid in
            switch pid {
            case 1111: return "/usr/local/bin/ios-use nslog --name unit"
            case 2222: return "dns-sd -R unit _nslogger-ssl._tcp local 51723"
            default: return nil
            }
        }
        NSLogService.killOverrideForTesting = { pid, signal in
            signals.append((pid, signal))
            alive.remove(pid)
            return 0
        }

        try NSLogService.acquireForegroundOwnership(paths: paths, mode: "flow")

        XCTAssertTrue(signals.contains { $0 == (1111, SIGTERM) })
        XCTAssertTrue(signals.contains { $0 == (2222, SIGTERM) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.nslogLock))
    }

    func testAcquireForegroundOwnershipDoesNotKillUnrelatedProcess() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true)
        try #"{"pid":3333,"port":51723,"startedAt":"old","iosUseHome":"\#(paths.root)","mode":"cli"}"#
            .write(toFile: paths.nslogLock, atomically: true, encoding: .utf8)
        var signals: [(Int32, Int32)] = []
        NSLogService.processAliveOverrideForTesting = { $0 == 3333 }
        NSLogService.processCommandOverrideForTesting = { _ in "/bin/sleep 60" }
        NSLogService.killOverrideForTesting = { pid, signal in
            signals.append((pid, signal))
            return 0
        }

        XCTAssertThrowsError(try NSLogService.acquireForegroundOwnership(paths: paths, mode: "cli")) { error in
            XCTAssertTrue(String(describing: error).contains("unrelated live process"))
            XCTAssertTrue(String(describing: error).contains(paths.nslogLock))
        }
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.nslogLock))
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

    private func makePaths() -> IOSUsePaths {
        IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-nslog-\(UUID().uuidString)").path
        ])
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
