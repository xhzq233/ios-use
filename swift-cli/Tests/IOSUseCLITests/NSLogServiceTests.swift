import XCTest
import Darwin
@testable import IOSUseCLI
@preconcurrency import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

final class NSLogServiceTests: XCTestCase {
    override func tearDown() {
        NSLogService.processCommandOverrideForTesting = nil
        NSLogService.processAliveOverrideForTesting = nil
        NSLogService.killOverrideForTesting = nil
        NSLogService.executablePathOverrideForTesting = nil
        NSLogService.processRunnerForTesting = nil
        Shell.runOverrideForTesting = nil
        Shell.runResultOverrideForTesting = nil
        super.tearDown()
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

    func testReadCaptureFiltersLastAndClearsFile() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        let logFile = "\(paths.logs)/nslog-test.log"
        try "alpha\nbeta\nalphabet\n".write(toFile: logFile, atomically: true, encoding: .utf8)
        let capture = NSLogCaptureTarget(logFile: logFile, name: "unit", startedAt: 1, stoppedAt: nil, status: "running", pid: 123, port: 456)

        let output = try NSLogService.readCapture(capture: capture, pattern: "alpha", flags: "", timeout: 0, clearAfterRead: true, last: 1)

        XCTAssertEqual(output, "alphabet\n")
        XCTAssertEqual(try String(contentsOfFile: logFile, encoding: .utf8), "")
    }

    func testNSLogReadUsesLastCaptureState() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true)
        let logFile = "\(paths.logs)/nslog-test.log"
        try "one\ntwo\nthree\n".write(toFile: logFile, atomically: true, encoding: .utf8)
        let state = NSLogState(lastCapture: NSLogCaptureTarget(logFile: logFile, name: "unit", startedAt: 1, stoppedAt: 2, status: "stopped", pid: nil, port: 456))
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: paths.nslogState))

        XCTAssertEqual(
            try NSLogService.read(options: NSLogOptions(command: .read, pattern: "t", last: 2), paths: paths),
            "two\nthree\n"
        )
    }

    func testNSLogReadFailsWithoutLastCapture() throws {
        let paths = makePaths()

        XCTAssertThrowsError(try NSLogService.read(options: NSLogOptions(command: .read), paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("ios-use nslog start"))
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

    func testServerAcceptsIPv4AndIPv6TLSClientFramesWithoutKeychain() throws {
        guard ipv6LoopbackAvailable() else {
            throw XCTSkip("IPv6 loopback is unavailable on this host")
        }
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-nslog-tls-\(UUID().uuidString)").path
        ])
        let server = try NSLoggerServer(options: NSLoggerServerOptions(publishBonjour: false), paths: paths)
        try server.start()
        defer { server.stop() }

        XCTAssertNotEqual(server.port, 0)
        XCTAssertNotEqual(server.port, 50_000)
        XCTAssertEqual(server.listenerAddresses, ["0.0.0.0:\(server.port)", "[::]:\(server.port)"])

        try sendTLSFrame(makeMessage(parts: [(7, 0, stringData("IPv4 TLS ready"))]), host: "127.0.0.1", port: UInt16(server.port))
        try sendTLSFrame(makeMessage(parts: [(7, 0, stringData("IPv6 TLS ready"))]), host: "::1", port: UInt16(server.port))

        let deadline = Date().addingTimeInterval(5)
        while server.logCount < 2, Date() < deadline {
            usleep(50_000)
        }

        XCTAssertEqual(server.clientCount, 2)
        XCTAssertEqual(try server.grep(pattern: "IPv4 TLS ready").count, 1)
        XCTAssertEqual(try server.grep(pattern: "IPv6 TLS ready").count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(paths.root)/runtime/nslogger-selfsigned.key"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(paths.root)/runtime/nslogger-selfsigned.crt"))

        let port = server.port
        server.stop()
        XCTAssertFalse(canOpenTCP(host: "127.0.0.1", port: port))
        XCTAssertFalse(canOpenTCP(host: "::1", port: port))
    }

    func testLockRecordsActualRandomPortAndBonjourPid() throws {
        let paths = makePaths()
        let server = try NSLoggerServer(options: NSLoggerServerOptions(name: "unit-nslog", publishBonjour: false), paths: paths)
        try server.start()
        defer { server.stop() }

        try NSLogService.writeLock(paths: paths, server: server, mode: "cli")
        let data = try Data(contentsOf: URL(fileURLWithPath: paths.nslogLock))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(json["port"] as? Int, server.port)
        XCTAssertEqual(json["iosUseHome"] as? String, paths.root)
        XCTAssertEqual(json["mode"] as? String, "cli")
        XCTAssertNil(json["bonjourPid"])
    }

    func testRequireCaptureSlotRemovesStaleLock() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true)
        try #"{"pid":424242,"port":50000,"startedAt":"old","iosUseHome":"\#(paths.root)","mode":"cli"}"#
            .write(toFile: paths.nslogLock, atomically: true, encoding: .utf8)
        NSLogService.processAliveOverrideForTesting = { _ in false }

        try NSLogService.requireCaptureSlot(paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.nslogLock))
    }

    func testRequireCaptureSlotDoesNotKillExistingIOSUseCapture() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true)
        try #"{"pid":1111,"bonjourPid":2222,"port":51723,"name":"unit","startedAt":"old","iosUseHome":"\#(paths.root)","mode":"cli"}"#
            .write(toFile: paths.nslogLock, atomically: true, encoding: .utf8)
        var signals: [(Int32, Int32)] = []
        NSLogService.processAliveOverrideForTesting = { $0 == 1111 || $0 == 2222 }
        NSLogService.processCommandOverrideForTesting = { pid in
            switch pid {
            case 1111: return "/usr/local/bin/ios-use nslog --name unit"
            case 2222: return "dns-sd -R unit _nslogger-ssl._tcp local 51723"
            default: return nil
            }
        }
        NSLogService.killOverrideForTesting = { pid, signal in
            signals.append((pid, signal))
            return 0
        }

        XCTAssertThrowsError(try NSLogService.requireCaptureSlot(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("NSLOG_ALREADY_RUNNING"))
        }
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.nslogLock))
    }

    func testRequireCaptureSlotDoesNotKillUnrelatedProcess() throws {
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

        XCTAssertThrowsError(try NSLogService.requireCaptureSlot(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("NSLOG_ALREADY_RUNNING"))
        }
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.nslogLock))
    }

    func testStopDoesNotKillUnrelatedProcessFromLock() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true)
        try #"{"pid":4444,"port":51723,"startedAt":"old","iosUseHome":"\#(paths.root)","mode":"daemon"}"#
            .write(toFile: paths.nslogLock, atomically: true, encoding: .utf8)
        var signals: [(Int32, Int32)] = []
        NSLogService.processAliveOverrideForTesting = { $0 == 4444 }
        NSLogService.processCommandOverrideForTesting = { _ in "/bin/sleep 60" }
        NSLogService.killOverrideForTesting = { pid, signal in
            signals.append((pid, signal))
            return 0
        }

        XCTAssertThrowsError(try NSLogService.stop(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("unrelated live process"))
            XCTAssertTrue(String(describing: error).contains(paths.nslogLock))
        }
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.nslogLock))
    }

    func testStartRefusesExistingLiveCaptureWithoutKillingIt() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true)
        try #"{"pid":5555,"port":51723,"startedAt":"old","iosUseHome":"\#(paths.root)","mode":"daemon"}"#
            .write(toFile: paths.nslogLock, atomically: true, encoding: .utf8)
        var signals: [(Int32, Int32)] = []
        NSLogService.processAliveOverrideForTesting = { $0 == 5555 }
        NSLogService.processCommandOverrideForTesting = { _ in "/usr/local/bin/ios-use nslog start" }
        NSLogService.killOverrideForTesting = { pid, signal in
            signals.append((pid, signal))
            return 0
        }

        XCTAssertThrowsError(try NSLogService.start(options: NSLogOptions(command: .start), paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("NSLOG_ALREADY_RUNNING"))
            XCTAssertTrue(String(describing: error).contains("ios-use nslog stop"))
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

    private func sendTLSFrame(_ data: Data, host: String, port: UInt16) throws {
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
        let channel = try bootstrap.connect(host: host, port: Int(port)).wait()
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try channel.writeAndFlush(buffer).wait()
        usleep(100_000)
        try channel.close().wait()
    }

    private func canOpenTCP(host: String, port: Int) -> Bool {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        do {
            let channel = try ClientBootstrap(group: group).connect(host: host, port: port).wait()
            try? channel.close().wait()
            return true
        } catch {
            return false
        }
    }

    private func ipv6LoopbackAvailable() -> Bool {
        guard let loopback = try? SocketAddress.makeAddressResolvingHost("::1", port: 0),
              let devices = try? System.enumerateDevices() else {
            return false
        }
        return devices.contains { $0.address == loopback }
    }
}
