import Darwin
import Foundation
import XCTest
import IOSUseProtocol
@testable import IOSUseDaemonRuntime

final class DaemonServerClientTests: XCTestCase {
    func testClientRequestRoundTripsThroughUnixSocketServer() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let request = DaemonRequest(id: "round-trip-1", argv: ["devices", "--simulator"], cwd: root)
        let server = DaemonServer(paths: paths) { incoming, _, _ in
            DaemonServer.Response(exit: DaemonExit(id: incoming.id, exitCode: incoming == request ? 0 : 2))
        }
        defer { server.stop() }

        try server.start()

        let exit = try DaemonTestClient(paths: paths).send(request)

        XCTAssertEqual(exit, DaemonExit(id: "round-trip-1", exitCode: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemonSocket))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemonPid))
    }

    func testStopRemovesSocketAndPidFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let server = DaemonServer(paths: paths) { request, _, _ in
            DaemonServer.Response(exit: DaemonExit(id: request.id, exitCode: 0))
        }

        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemonSocket))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemonPid))

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.daemonSocket))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.daemonPid))
    }

    func testStopResponseRemovesSocketAndPidAfterExitIsReturned() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let server = DaemonServer(paths: paths) { request, _, _ in
            DaemonServer.Response(
                exit: DaemonExit(id: request.id, exitCode: 0),
                shouldStopDaemon: true
            )
        }

        try server.start()
        let exit = try DaemonTestClient(paths: paths).send(DaemonRequest(id: "stop-1", argv: ["stop"], cwd: root))

        XCTAssertEqual(exit, DaemonExit(id: "stop-1", exitCode: 0))
        XCTAssertTrue(waitUntilMissing(paths.daemonSocket))
        XCTAssertTrue(waitUntilMissing(paths.daemonPid))
    }

    func testStartDoesNotUnlinkLiveDaemonSocketWhenAnotherDaemonStarts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let server = DaemonServer(paths: paths) { request, _, _ in
            DaemonServer.Response(exit: DaemonExit(id: request.id, exitCode: 0))
        }
        defer { server.stop() }

        try server.start()
        let duplicate = DaemonServer(paths: paths) { request, _, _ in
            DaemonServer.Response(exit: DaemonExit(id: request.id, exitCode: 2))
        }

        XCTAssertThrowsError(try duplicate.start()) { error in
            XCTAssertTrue(String(describing: error).contains("already running"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemonSocket))
        let exit = try DaemonTestClient(paths: paths).send(DaemonRequest(id: "still-live", argv: ["devices"], cwd: root))
        XCTAssertEqual(exit, DaemonExit(id: "still-live", exitCode: 0))
    }

    func testClientPassesOutputFileDescriptorsToServer() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let server = DaemonServer(paths: paths) { request, output, _ in
            output.writeStdout("stdout from daemon\n")
            output.writeStderr("stderr from daemon\n")
            return DaemonServer.Response(exit: DaemonExit(id: request.id, exitCode: 7))
        }
        defer { server.stop() }

        try server.start()
        let request = DaemonRequest(id: "fd-pass-1", argv: ["devices", "--simulator"], cwd: root)
        let exit = try DaemonTestClient(paths: paths).send(
            request,
            stdoutFileDescriptor: stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderrFileDescriptor: stderrPipe.fileHandleForWriting.fileDescriptor
        )
        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()

        XCTAssertEqual(exit, DaemonExit(id: "fd-pass-1", exitCode: 7))
        XCTAssertEqual(String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "stdout from daemon\n")
        XCTAssertEqual(String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "stderr from daemon\n")
    }

    func testDaemonExecutorRunsParsedCommandAndWritesToPassedStdout() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let executor = DaemonExecutor(environment: ["IOS_USE_HOME": root])
        let server = DaemonServer(paths: paths) { request, output, cancellation in
            executor.handle(request, output: output, cancellation: cancellation)
        }
        defer { server.stop() }

        try server.start()
        let request = DaemonRequest(id: "execute-1", argv: ["config", "--list"], cwd: root)
        let exit = try DaemonTestClient(paths: paths).send(
            request,
            stdoutFileDescriptor: stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderrFileDescriptor: stderrPipe.fileHandleForWriting.fileDescriptor
        )
        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()

        XCTAssertEqual(exit, DaemonExit(id: "execute-1", exitCode: 0))
        XCTAssertEqual(String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "No configured devices.\n")
        XCTAssertEqual(String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "")
        let daemonLog = try String(contentsOfFile: paths.daemonLog)
        XCTAssertTrue(daemonLog.contains("[daemon] [INFO] request execute-1 argv=config --list"))
    }

    func testDaemonLoggerRedactsSensitiveRawArguments() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let logger = DaemonLogger(paths: paths)
        let runner = DaemonCommandRunner(
            environment: ["IOS_USE_HOME": root],
            paths: paths,
            output: DaemonOutputHandles(stdout: nil, stderr: nil),
            driverChannel: DaemonDriverChannel(paths: paths, logger: logger),
            logger: logger
        )
        let request = DaemonRequest(
            id: "redact-1",
            argv: ["config", "--apple-id", "user@example.com", "--password=secret", "--list"],
            cwd: root
        )

        _ = runner.run(request, parsed: nil)

        let daemonLog = try String(contentsOfFile: paths.daemonLog)
        XCTAssertTrue(daemonLog.contains("--apple-id <redacted>"))
        XCTAssertTrue(daemonLog.contains("--password=<redacted>"))
        XCTAssertFalse(daemonLog.contains("user@example.com"))
        XCTAssertFalse(daemonLog.contains("secret"))
    }

    func testInterruptMarksRunningRequestToken() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let resultBox = AsyncDaemonExitBox()
        let request = DaemonRequest(id: "interrupt-1", argv: ["devices"], cwd: root)
        let server = DaemonServer(paths: paths) { request, _, cancellation in
            started.signal()
            let deadline = Date().addingTimeInterval(2)
            while !cancellation.isCancelled && Date() < deadline {
                usleep(10_000)
            }
            return DaemonServer.Response(
                exit: cancellation.isCancelled
                    ? cancellation.cancelledExit(id: request.id)
                    : DaemonExit(id: request.id, exitCode: 2)
            )
        }
        defer { server.stop() }

        try server.start()
        DispatchQueue.global().async {
            do {
                resultBox.set(.success(try DaemonTestClient(paths: paths).send(request)))
            } catch {
                resultBox.set(.failure(error))
            }
            completed.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let interruptExit = try DaemonTestClient(paths: paths).send(.interrupt(DaemonInterrupt(id: request.id, signal: "SIGINT")))

        XCTAssertEqual(interruptExit, DaemonExit(id: request.id, exitCode: 130))
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try resultBox.get(), DaemonExit(id: request.id, exitCode: 130))
    }

    func testDaemonExecutorCancelsRunningDriverCommandByClosingChannel() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let driverServer = try DaemonExecutorFakeDriverServer(responses: [
            .waitFor(label: "Ready", delay: 5),
        ])
        defer { driverServer.stop() }

        DriverBootstrap.endpointResolverForTesting = { session, current, _ in
            DriverEndpoint(
                udid: session.udid ?? current?.udid ?? "SIM-DAEMON",
                port: driverServer.port,
                deviceName: "Fake Simulator",
                deviceVersion: "17.0",
                deviceType: "simulator"
            )
        }
        addTeardownBlock { DriverBootstrap.endpointResolverForTesting = nil }

        let executor = DaemonExecutor(environment: ["IOS_USE_HOME": root])
        let token = DaemonCancellationToken()
        let completed = DispatchSemaphore(value: 0)
        let exitBox = AsyncDaemonExitBox()
        let request = DaemonRequest(
            id: "daemon-wait-cancel",
            argv: ["waitFor", "--label", "Ready", "--timeout", "10", "--udid", "SIM-DAEMON"],
            cwd: root
        )

        DispatchQueue.global().async {
            let response = executor.handle(
                request,
                output: DaemonOutputHandles(stdout: nil, stderr: nil),
                cancellation: token
            )
            exitBox.set(.success(response.exit))
            completed.signal()
        }

        XCTAssertTrue(driverServer.waitForCommandCount(1))
        let cancelledAt = Date()
        token.cancel(signal: "SIGINT")

        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try exitBox.get(), DaemonExit(id: request.id, exitCode: 130))
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
    }

    func testDaemonExecutorReusesActiveDriverChannelAcrossRequests() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let driverServer = try DaemonExecutorFakeDriverServer(responses: [
            .dom(app: "fake-one"),
            .dom(app: "fake-two"),
        ])
        defer { driverServer.stop() }

        DriverBootstrap.endpointResolverForTesting = { session, current, _ in
            DriverEndpoint(
                udid: session.udid ?? current?.udid ?? "SIM-DAEMON",
                port: driverServer.port,
                deviceName: "Fake Simulator",
                deviceVersion: "17.0",
                deviceType: "simulator"
            )
        }
        addTeardownBlock { DriverBootstrap.endpointResolverForTesting = nil }

        let executor = DaemonExecutor(environment: ["IOS_USE_HOME": root])
        let first = executor.handle(
            DaemonRequest(id: "daemon-dom-1", argv: ["dom", "--udid", "SIM-DAEMON"], cwd: root),
            output: DaemonOutputHandles(stdout: nil, stderr: nil)
        )
        let second = executor.handle(
            DaemonRequest(id: "daemon-dom-2", argv: ["dom", "--udid", "SIM-DAEMON"], cwd: root),
            output: DaemonOutputHandles(stdout: nil, stderr: nil)
        )

        XCTAssertEqual(first.exit, DaemonExit(id: "daemon-dom-1", exitCode: 0))
        XCTAssertEqual(second.exit, DaemonExit(id: "daemon-dom-2", exitCode: 0))
        XCTAssertEqual(driverServer.acceptCount, 1)
        XCTAssertEqual(driverServer.requestCommands, ["dom", "dom"])
        let daemonLog = try String(contentsOfFile: paths.daemonLog)
        XCTAssertEqual(daemonLog.components(separatedBy: "opened driver channel").count - 1, 1)
    }

    func testDaemonExecutorQueuesConcurrentDriverRequestsBeforeResolvingEndpoint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let driverServer = try DaemonExecutorFakeDriverServer(responses: [
            .waitFor(label: "Ready", delay: 0.5),
            .dom(app: "after-wait"),
        ])
        defer { driverServer.stop() }

        let resolverTimes = LockedDates()
        DriverBootstrap.endpointResolverForTesting = { session, current, _ in
            resolverTimes.append(Date())
            return DriverEndpoint(
                udid: session.udid ?? current?.udid ?? "SIM-DAEMON",
                port: driverServer.port,
                deviceName: "Fake Simulator",
                deviceVersion: "17.0",
                deviceType: "simulator"
            )
        }
        addTeardownBlock { DriverBootstrap.endpointResolverForTesting = nil }

        let executor = DaemonExecutor(environment: ["IOS_USE_HOME": root])
        let waitCompleted = DispatchSemaphore(value: 0)
        let domCompleted = DispatchSemaphore(value: 0)
        let waitExit = AsyncDaemonExitBox()
        let domExit = AsyncDaemonExitBox()

        DispatchQueue.global().async {
            let response = executor.handle(
                DaemonRequest(
                    id: "daemon-wait-1",
                    argv: ["waitFor", "--label", "Ready", "--timeout", "1", "--udid", "SIM-DAEMON"],
                    cwd: root
                ),
                output: DaemonOutputHandles(stdout: nil, stderr: nil)
            )
            waitExit.set(.success(response.exit))
            waitCompleted.signal()
        }

        XCTAssertTrue(driverServer.waitForCommandCount(1))

        DispatchQueue.global().async {
            let response = executor.handle(
                DaemonRequest(id: "daemon-dom-queued", argv: ["dom", "--udid", "SIM-DAEMON"], cwd: root),
                output: DaemonOutputHandles(stdout: nil, stderr: nil)
            )
            domExit.set(.success(response.exit))
            domCompleted.signal()
        }

        XCTAssertEqual(waitCompleted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(domCompleted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(try waitExit.get(), DaemonExit(id: "daemon-wait-1", exitCode: 0))
        XCTAssertEqual(try domExit.get(), DaemonExit(id: "daemon-dom-queued", exitCode: 0))
        XCTAssertEqual(driverServer.requestCommands, ["waitFor", "dom"])

        let times = resolverTimes.values
        XCTAssertEqual(times.count, 2)
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 0.35)
    }

    func testStopTerminatesActiveSimulatorDriverAndDaemon() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let driverServer = try DaemonExecutorFakeDriverServer(responses: [
            .dom(app: "fake-before-stop"),
        ])
        defer { driverServer.stop() }
        var terminated: [String] = []

        DriverBootstrap.endpointResolverForTesting = { session, current, _ in
            DriverEndpoint(
                udid: session.udid ?? current?.udid ?? "SIM-DAEMON",
                port: driverServer.port,
                deviceName: "Fake Simulator",
                deviceVersion: "17.0",
                deviceType: "simulator"
            )
        }
        DriverBootstrap.simulatorDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return true
        }
        addTeardownBlock {
            DriverBootstrap.endpointResolverForTesting = nil
            DriverBootstrap.simulatorDriverTerminatorForTesting = nil
        }

        let executor = DaemonExecutor(environment: ["IOS_USE_HOME": root])
        let dom = executor.handle(
            DaemonRequest(id: "daemon-dom-before-stop", argv: ["dom", "--udid", "SIM-DAEMON"], cwd: root),
            output: DaemonOutputHandles(stdout: nil, stderr: nil)
        )
        let stop = executor.handle(
            DaemonRequest(id: "daemon-stop", argv: ["stop"], cwd: root),
            output: DaemonOutputHandles(stdout: nil, stderr: nil)
        )

        XCTAssertEqual(dom.exit, DaemonExit(id: "daemon-dom-before-stop", exitCode: 0))
        XCTAssertEqual(stop.exit, DaemonExit(id: "daemon-stop", exitCode: 0))
        XCTAssertTrue(stop.shouldStopDaemon)
        XCTAssertEqual(terminated, ["SIM-DAEMON"])
    }

    func testDaemonQueueKeyUsesSingleActiveDriverQueue() throws {
        XCTAssertEqual(try CLIParser.parse(["dom", "--udid", "A"]).daemonQueueKey(activeEndpoint: nil), "__driver__")
        XCTAssertEqual(try CLIParser.parse(["tap", "Settings", "--udid", "B"]).daemonQueueKey(activeEndpoint: nil), "__driver__")
        XCTAssertEqual(try CLIParser.parse(["flow", "flows/test.yaml", "--udid", "C"]).daemonQueueKey(activeEndpoint: nil), "__driver__")
        XCTAssertEqual(try CLIParser.parse(["config", "--simulator", "--udid", "D"]).daemonQueueKey(activeEndpoint: nil), "__driver__")
        XCTAssertEqual(try CLIParser.parse(["proxy", "configca", "--udid", "E"]).daemonQueueKey(activeEndpoint: nil), "__driver__")
        XCTAssertNil(try CLIParser.parse(["devices"]).daemonQueueKey(activeEndpoint: nil))
        XCTAssertNil(try CLIParser.parse(["oslog", "--udid", "A"]).daemonQueueKey(activeEndpoint: nil))
    }

    func testStreamingAndLocalCommandsDoNotRequireDaemonCwdLock() throws {
        XCTAssertFalse(try CLIParser.parse(["devices"]).requiresDaemonWorkingDirectory)
        XCTAssertFalse(try CLIParser.parse(["nslog"]).requiresDaemonWorkingDirectory)
        XCTAssertFalse(try CLIParser.parse(["oslog", "--udid", "A"]).requiresDaemonWorkingDirectory)
        XCTAssertFalse(try CLIParser.parse(["proxy", "doctor"]).requiresDaemonWorkingDirectory)
        XCTAssertTrue(try CLIParser.parse(["dom", "--udid", "A"]).requiresDaemonWorkingDirectory)
        XCTAssertTrue(try CLIParser.parse(["flow", "flows/test.yaml", "--udid", "C"]).requiresDaemonWorkingDirectory)
        XCTAssertTrue(try CLIParser.parse(["config", "--simulator", "--udid", "D"]).requiresDaemonWorkingDirectory)
    }

    private func temporaryRoot() throws -> String {
        let suffix = UUID().uuidString.prefix(8)
        let root = "/tmp/iud-\(suffix)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntilMissing(_ path: String) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: path) {
                return true
            }
            usleep(10_000)
        }
        return !FileManager.default.fileExists(atPath: path)
    }
}

private final class DaemonExecutorFakeDriverServer {
    struct Response {
        let frame: ForyResponseFrame
        let delay: TimeInterval

        static func dom(app: String) -> Response {
            let payload = try! ForyRegistry.create().serialize(ForyDomPayload(
                app: app,
                windowSize: ForyPoint(x: 390, y: 844),
                elements: []
            ))
            return Response(frame: ForyResponseFrame(ok: true, payload: payload), delay: 0)
        }

        static func waitFor(label: String, delay: TimeInterval) -> Response {
            let payload = try! ForyRegistry.create().serialize(ForyWaitForPayload(
                elemType: 9,
                label: label,
                rect: ForyRect(x: 1, y: 2, w: 3, h: 4),
                waited: delay
            ))
            return Response(frame: ForyResponseFrame(ok: true, payload: payload), delay: delay)
        }
    }

    let port: Int
    private let listenFD: Int32
    private let responses: [Response]
    private let lock = NSLock()
    private var thread: Thread?
    private var stopped = false
    private var accepted = 0
    private var nextResponseIndex = 0
    private var commands: [String] = []
    private let fory = ForyRegistry.create()

    init(responses: [Response]) throws {
        self.responses = responses
        let fd = try Self.makeListenSocket()
        self.listenFD = fd.listenFD
        self.port = fd.port
        let worker = Thread { [weak self] in self?.serve() }
        thread = worker
        worker.start()
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

    func waitForCommandCount(_ count: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let ready = commands.count >= count
            lock.unlock()
            if ready { return true }
            usleep(10_000)
        }
        lock.lock()
        let ready = commands.count >= count
        lock.unlock()
        return ready
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
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
        guard listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("listen failed: \(errno)")
        }
        return (fd, Int(UInt16(bigEndian: bound.sin_port)))
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
        defer { Darwin.close(clientFD) }
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
            let response = responses[nextResponseIndex]
            nextResponseIndex += 1
            lock.unlock()

            if response.delay > 0 {
                usleep(useconds_t(response.delay * 1_000_000))
            }
            guard let frame = try? fory.serialize(response.frame) else { return }
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
        try withUnsafeBytes(of: &length) { buffer in
            try writeExact(fd: fd, pointer: buffer.baseAddress!, count: 4)
        }
        try data.withUnsafeBytes { buffer in
            try writeExact(fd: fd, pointer: buffer.baseAddress!, count: data.count)
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

    private func writeExact(fd: Int32, pointer: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, pointer.advanced(by: offset), count - offset)
            if written <= 0 { throw CLIParseError.invalidValue("write failed") }
            offset += written
        }
    }
}

private final class DaemonTestClient {
    private let paths: IOSUsePaths

    init(paths: IOSUsePaths) {
        self.paths = paths
    }

    func send(
        _ request: DaemonRequest,
        stdoutFileDescriptor: Int32? = nil,
        stderrFileDescriptor: Int32? = nil
    ) throws -> DaemonExit {
        try send(.request(request), fileDescriptors: [stdoutFileDescriptor, stderrFileDescriptor].compactMap { $0 })
    }

    func send(_ message: DaemonControlMessage, fileDescriptors: [Int32] = []) throws -> DaemonExit {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonSocketError.socketFailure(daemonErrnoMessage("socket")) }
        defer { close(fd) }

        var address = try daemonUnixAddress(path: paths.daemonSocket)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + paths.daemonSocket.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }
        guard result == 0 else { throw DaemonSocketError.socketFailure(daemonErrnoMessage("connect")) }
        try sendFrame(message, fileDescriptors: fileDescriptors, fd: fd)
        let response = try readFrame(fd: fd)
        guard case .exit(let exit) = try DaemonControlProtocol.decode(response) else {
            throw DaemonSocketError.socketFailure("daemon returned an unexpected control message")
        }
        return exit
    }

    private func sendFrame(_ message: DaemonControlMessage, fileDescriptors: [Int32], fd: Int32) throws {
        let data = try DaemonControlProtocol.encode(message)
        try data.withUnsafeBytes { dataPointer in
            var iov = iovec(
                iov_base: UnsafeMutableRawPointer(mutating: dataPointer.baseAddress),
                iov_len: data.count
            )
            try withUnsafeMutablePointer(to: &iov) { iovPointer in
                var header = msghdr()
                header.msg_iov = iovPointer
                header.msg_iovlen = 1

                var control = [UInt8]()
                if !fileDescriptors.isEmpty {
                    control = [UInt8](repeating: 0, count: daemonCmsgSpace(fileDescriptors.count))
                    try control.withUnsafeMutableBytes { controlPointer in
                        header.msg_control = controlPointer.baseAddress
                        header.msg_controllen = socklen_t(controlPointer.count)
                        guard let first = daemonFirstCmsg(&header) else {
                            throw DaemonSocketError.socketFailure("failed to create daemon fd control header")
                        }
                        first.pointee.cmsg_len = socklen_t(daemonCmsgLength(fileDescriptors.count))
                        first.pointee.cmsg_level = SOL_SOCKET
                        first.pointee.cmsg_type = SCM_RIGHTS
                        let fdPointer = daemonCmsgData(first).assumingMemoryBound(to: Int32.self)
                        for (index, descriptor) in fileDescriptors.enumerated() {
                            fdPointer[index] = descriptor
                        }
                        guard sendmsg(fd, &header, 0) == data.count else {
                            throw DaemonSocketError.socketFailure(daemonErrnoMessage("sendmsg"))
                        }
                    }
                } else {
                    guard sendmsg(fd, &header, 0) == data.count else {
                        throw DaemonSocketError.socketFailure(daemonErrnoMessage("sendmsg"))
                    }
                }
            }
        }
    }

    private func readFrame(fd: Int32) throws -> Data {
        var data = Data()
        var byte = UInt8(0)
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                data.append(byte)
                if byte == 0x0a { return data }
            } else if count == 0 {
                throw DaemonSocketError.connectionClosedBeforeExit
            } else if errno != EINTR {
                throw DaemonSocketError.socketFailure(daemonErrnoMessage("read"))
            }
        }
    }
}

private final class AsyncDaemonExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<DaemonExit, Error>?

    func set(_ result: Result<DaemonExit, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> DaemonExit {
        lock.lock()
        let result = self.result
        lock.unlock()
        switch result {
        case .success(let exit):
            return exit
        case .failure(let error):
            throw error
        case nil:
            throw DaemonSocketError.connectionClosedBeforeExit
        }
    }
}

private final class LockedDates: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Date] = []

    var values: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: Date) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}
