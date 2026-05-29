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

        try NSLogService.writeLock(paths: paths, server: server, mode: "flow")
        let data = try Data(contentsOf: URL(fileURLWithPath: paths.nslogLock))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(json["port"] as? Int, server.port)
        XCTAssertEqual(json["iosUseHome"] as? String, paths.root)
        XCTAssertEqual(json["mode"] as? String, "flow")
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
        try #"{"pid":5555,"port":51723,"startedAt":"old","iosUseHome":"\#(paths.root)","mode":"flow"}"#
            .write(toFile: paths.nslogLock, atomically: true, encoding: .utf8)
        var signals: [(Int32, Int32)] = []
        NSLogService.processAliveOverrideForTesting = { $0 == 5555 }
        NSLogService.processCommandOverrideForTesting = { _ in "/usr/local/bin/ios-use flow active.yaml" }
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

    func testResolveExecutablePathUsesPathForInstalledInvocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-nslog-path-\(UUID().uuidString)").path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: "\(root)/bin", withIntermediateDirectories: true)
        let executable = "\(root)/bin/ios-use"
        FileManager.default.createFile(atPath: executable, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        XCTAssertEqual(
            try NSLogService.resolveExecutablePath(arg0: "ios-use", environment: ["PATH": "\(root)/bin:/usr/bin"], currentDirectoryPath: "\(root)/other"),
            executable
        )
    }

    func testBonjourDiagnosticsParsesLocalPublishersWithSpacesAndDeduplicates() {
        let ps = """
          PID ARGS
        1000 /usr/bin/dns-sd -R stale service _nslogger-ssl._tcp local 51082
        1000 /usr/bin/dns-sd -R stale service _nslogger-ssl._tcp local 51082
        2000 dns-sd -R live-service _nslogger-ssl._tcp local 62000
        2500 /usr/bin/env dns-sd -R env-service _nslogger-ssl._tcp local 62001
        3000 dns-sd -R other _http._tcp local 8080
        4000 /bin/zsh -c dns-sd -R script-text _nslogger-ssl._tcp local 59999
        """

        let conflicts = NSLoggerBonjourDiagnostics.diagnoseExistingServices(psOutput: ps) { $0 == 62000 || $0 == 62001 }

        XCTAssertEqual(conflicts, [
            NSLoggerBonjourConflict(kind: .staleLocalPublisher, name: "stale service", port: 51082, pid: 1000),
            NSLoggerBonjourConflict(kind: .liveNSLogServer, name: "live-service", port: 62000, pid: 2000),
            NSLoggerBonjourConflict(kind: .liveNSLogServer, name: "env-service", port: 62001, pid: 2500)
        ])
    }

    func testBonjourDiagnosticsReturnsEmptyWhenProcessScanFails() {
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            XCTAssertEqual(executable, "ps")
            XCTAssertEqual(arguments, ["-axo", "pid,args"])
            throw CLIParseError.invalidValue("ps failed")
        }

        XCTAssertTrue(NSLoggerBonjourDiagnostics.diagnoseExistingServices().isEmpty)
    }

    func testBonjourDiagnosticsReturnsEmptyForNoLocalPublishers() {
        let ps = """
          PID ARGS
        1000 /bin/zsh
        2000 dns-sd -R web _http._tcp local 8080
        """

        XCTAssertTrue(NSLoggerBonjourDiagnostics.diagnoseExistingServices(psOutput: ps) { _ in true }.isEmpty)
    }

    func testBonjourDiagnosticsTreatsListenerCheckFailureAsStale() {
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "ps" {
                return "1000 dns-sd -R stale-service _nslogger-ssl._tcp local 51082\n"
            }
            XCTAssertEqual(executable, "lsof")
            XCTAssertEqual(arguments, ["-nP", "-iTCP:51082", "-sTCP:LISTEN"])
            throw CLIParseError.invalidValue("lsof failed")
        }

        XCTAssertEqual(NSLoggerBonjourDiagnostics.diagnoseExistingServices(), [
            NSLoggerBonjourConflict(kind: .staleLocalPublisher, name: "stale-service", port: 51082, pid: 1000)
        ])
    }

    func testBonjourDiagnosticsUsesLsofToClassifyLiveServer() {
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "ps" {
                return "2000 dns-sd -R live-service _nslogger-ssl._tcp local 62000\n"
            }
            XCTAssertEqual(executable, "lsof")
            XCTAssertEqual(arguments, ["-nP", "-iTCP:62000", "-sTCP:LISTEN"])
            return "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nios-use 42 user 10u IPv4 0 0t0 TCP *:62000 (LISTEN)\n"
        }

        XCTAssertEqual(NSLoggerBonjourDiagnostics.diagnoseExistingServices(), [
            NSLoggerBonjourConflict(kind: .liveNSLogServer, name: "live-service", port: 62000, pid: 2000)
        ])
    }

    func testBonjourDiagnosticsWarningIncludesClassificationNamePidAndPort() {
        let warning = NSLoggerBonjourDiagnostics.formatWarning([
            NSLoggerBonjourConflict(kind: .staleLocalPublisher, name: "stale service", port: 51082, pid: 1000),
            NSLoggerBonjourConflict(kind: .liveNSLogServer, name: "live-service", port: 62000, pid: 2000)
        ])

        XCTAssertTrue(warning.contains("existing NSLogger Bonjour services"))
        XCTAssertTrue(warning.contains("stale local publisher: stale service (pid=1000 port=51082, no TCP listener)"))
        XCTAssertTrue(warning.contains("live nslog server: live-service (pid=2000 port=62000)"))
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
