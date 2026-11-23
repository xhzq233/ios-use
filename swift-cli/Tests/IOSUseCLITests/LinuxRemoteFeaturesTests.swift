#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation
import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class LinuxRemoteFeaturesTests: XCTestCase {
    override func tearDown() {
        DriverCommandExecution.clientFactoryForTesting = nil
        DriverLifecycleService.holderLauncherForTesting = nil
        DriverLifecycleService.holderTerminatorForTesting = nil
        DriverLifecycleService.processAliveForTesting = nil
        RealDeviceOSTraceService.collectorForTesting = nil
        super.tearDown()
    }

    private func withTempHome(_ body: (String, IOSUsePaths) throws -> Void) throws {
        // Keep paths short so Unix domain socket paths stay under sun_path limits.
        let root = "/tmp/iu-lrf-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try body(root, paths)
    }

    private func writeRemoteHolderLock(
        udid: String = "REMOTE-1",
        alias: String = "phone",
        usbmuxPort: Int,
        driverPort: Int,
        holderPid: Int,
        runnerPid: Int = 9001,
        sessionIdentifier: String = "SESSION-OLD",
        controlSocketPath: String? = nil,
        paths: IOSUsePaths
    ) throws -> IOSUsePaths {
        let scoped = try paths.deviceContext(alias)
        let connection = RemoteDeviceConnection(
            udid: udid,
            driverBundleID: "com.example.driver.xctrunner",
            usbmux: .init(host: "127.0.0.1", port: usbmuxPort),
            driver: .init(host: "127.0.0.1", port: driverPort)
        )
        try DriverSessionStore.write(
            info: SessionService.Info(
                udid: udid,
                deviceName: "Remote iPhone",
                deviceVersion: "",
                deviceType: "real",
                driverHost: connection.driver.host,
                driverPort: connection.driver.port,
                remoteConnection: connection,
                holderPid: holderPid,
                runnerPid: runnerPid,
                startMode: "remote",
                sessionIdentifier: sessionIdentifier,
                bundleId: connection.driverBundleID,
                controlSocketPath: controlSocketPath ?? "\(scoped.root)/state/missing-holder.sock"
            ),
            paths: scoped
        )
        return scoped
    }

    func testRemoteSessionAutoRecoversWhenUsbmuxIsReachableOnConnectFailure() throws {
        try withTempHome { root, paths in
            let usbmux = try LoopbackListener()
            defer { usbmux.stop() }
            let driver = try FakeDriverServer(responseCount: 1)
            defer { driver.stop() }

            let scoped = try writeRemoteHolderLock(
                usbmuxPort: usbmux.port,
                driverPort: driver.port,
                holderPid: 4242,
                paths: paths
            )
            DriverLifecycleService.processAliveForTesting = { _ in false }

            var attempts = 0
            DriverCommandExecution.clientFactoryForTesting = { _ in
                attempts += 1
                if attempts == 1 {
                    return FailingConnectDriverClient(error: DriverClientError.connectFailed(ECONNREFUSED))
                }
                return RecordingDomDriverClient()
            }

            var launches = 0
            var cleanupCalls = 0
            DriverLifecycleService.holderTerminatorForTesting = { info, _ in
                cleanupCalls += 1
                XCTAssertEqual(info.holderPid, 4242)
                return .alreadyStopped
            }
            DriverLifecycleService.holderLauncherForTesting = { udid, bundleId, _, _ in
                launches += 1
                XCTAssertEqual(udid, "REMOTE-1")
                XCTAssertEqual(bundleId, "com.example.driver.xctrunner")
                return DriverLifecycleService.LaunchMetadata(
                    holderPid: 8484,
                    runnerPid: 9595,
                    sessionIdentifier: "SESSION-RECOVERED",
                    bundleId: bundleId,
                    controlSocketPath: "\(root)/state/holder-recovered.sock"
                )
            }

            let session = LockedDriverClientSession(paths: scoped)
            defer { session.close() }
            let payload = try session.run { try $0.dom(raw: false, waitQuiescence: false) }

            XCTAssertEqual(payload.app, "recovered")
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(cleanupCalls, 1)
            XCTAssertEqual(launches, 1)
            let updated = try XCTUnwrap(DriverSessionStore.readInfo(paths: scoped))
            XCTAssertEqual(updated.holderPid, 8484)
            XCTAssertEqual(updated.runnerPid, 9595)
            XCTAssertEqual(updated.sessionIdentifier, "SESSION-RECOVERED")
        }
    }

    func testRemoteSessionAutoRecoversOnReadFailureBehindForwarderWhenHolderStopped() throws {
        try withTempHome { root, paths in
            let usbmux = try LoopbackListener()
            defer { usbmux.stop() }
            let driver = try FakeDriverServer(responseCount: 1)
            defer { driver.stop() }
            // Forwarder starts with no backend -> accepts TCP and closes immediately (EOF / readFailed).
            let forwarder = try SwitchableLoopbackForwarder(initialTargetPort: nil)
            defer { forwarder.stop() }

            let scoped = try writeRemoteHolderLock(
                usbmuxPort: usbmux.port,
                driverPort: forwarder.port,
                holderPid: 5151,
                paths: paths
            )
            DriverLifecycleService.processAliveForTesting = { _ in false }
            DriverLifecycleService.holderTerminatorForTesting = { _, _ in .alreadyStopped }
            var launches = 0
            DriverLifecycleService.holderLauncherForTesting = { _, bundleId, _, _ in
                launches += 1
                forwarder.targetPort = driver.port
                return DriverLifecycleService.LaunchMetadata(
                    holderPid: 6161,
                    runnerPid: 7171,
                    sessionIdentifier: "SESSION-FORWARDED",
                    bundleId: bundleId,
                    controlSocketPath: "\(root)/state/holder-forwarded.sock"
                )
            }

            let session = LockedDriverClientSession(paths: scoped)
            defer { session.close() }
            let payload = try session.run { try $0.dom(raw: false, waitQuiescence: false) }

            XCTAssertEqual(payload.app, "fake")
            XCTAssertEqual(launches, 1)
            XCTAssertEqual(driver.requestCommands, ["dom"])
            let updated = try XCTUnwrap(DriverSessionStore.readInfo(paths: scoped))
            XCTAssertEqual(updated.holderPid, 6161)
            XCTAssertEqual(updated.sessionIdentifier, "SESSION-FORWARDED")
        }
    }

    func testRemoteSessionDoesNotRecoverOnReadFailureWhenHolderIsStillHealthy() throws {
        try withTempHome { root, paths in
            let usbmux = try LoopbackListener()
            defer { usbmux.stop() }
            let socketPath = "\(root)/holder.sock"
            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            let state = XCTestSessionHolderControlState(
                holderPid: pid,
                bundleId: "com.example.driver.xctrunner",
                controlSocketPath: socketPath
            )
            state.markReady(runnerPid: 9001, sessionIdentifier: "SESSION-HEALTHY")
            let controlServer = XCTestSessionHolderControlServer(socketPath: socketPath, state: state)
            try controlServer.start()
            defer { controlServer.stop() }

            let scoped = try writeRemoteHolderLock(
                usbmuxPort: usbmux.port,
                driverPort: 1,
                holderPid: pid,
                runnerPid: 9001,
                sessionIdentifier: "SESSION-HEALTHY",
                controlSocketPath: socketPath,
                paths: paths
            )
            let original = try XCTUnwrap(DriverSessionStore.readInfo(paths: scoped))

            DriverCommandExecution.clientFactoryForTesting = { _ in
                FailingConnectDriverClient(error: DriverClientError.readFailed)
            }
            var launches = 0
            DriverLifecycleService.holderLauncherForTesting = { _, _, _, _ in
                launches += 1
                fatalError("must not relaunch a healthy holder")
            }

            let session = LockedDriverClientSession(paths: scoped)
            defer { session.close() }
            XCTAssertThrowsError(try session.run { try $0.dom(raw: false, waitQuiescence: false) })
            XCTAssertEqual(launches, 0)
            XCTAssertEqual(try DriverSessionStore.readInfo(paths: scoped), original)
        }
    }

    func testRemoteSessionFailsFastWithProviderHintWhenUsbmuxIsUnreachable() throws {
        try withTempHome { _, paths in
            let closedUsbmuxPort = try reserveUnusedLocalPort()
            let scoped = try writeRemoteHolderLock(
                alias: "dora",
                usbmuxPort: closedUsbmuxPort,
                driverPort: 1,
                holderPid: 4242,
                paths: paths
            )
            let original = try XCTUnwrap(DriverSessionStore.readInfo(paths: scoped))
            DriverLifecycleService.processAliveForTesting = { _ in false }
            DriverCommandExecution.clientFactoryForTesting = { _ in
                FailingConnectDriverClient(error: DriverClientError.connectFailed(ECONNREFUSED))
            }
            var launches = 0
            DriverLifecycleService.holderLauncherForTesting = { _, _, _, _ in
                launches += 1
                fatalError("must not relaunch when usbmux is down")
            }

            let session = LockedDriverClientSession(paths: scoped)
            defer { session.close() }
            XCTAssertThrowsError(try session.run { try $0.dom(raw: false, waitQuiescence: false) }) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("Remote device transport is unreachable"))
                XCTAssertTrue(message.contains("127.0.0.1:\(closedUsbmuxPort)"))
                XCTAssertTrue(message.contains("ios-use stop -d dora"))
            }
            XCTAssertEqual(launches, 0)
            XCTAssertEqual(try DriverSessionStore.readInfo(paths: scoped), original)
        }
    }

    func testRemoteStartReclaimsDeadHolderLockOnSameAliasOnly() throws {
        try withTempHome { root, paths in
            let usbmux = try LoopbackListener()
            defer { usbmux.stop() }
            let driver = try FakeDriverServer(responseCount: 1)
            defer { driver.stop() }

            let stale = try writeRemoteHolderLock(
                udid: "REMOTE-RECLAIM",
                alias: "phone",
                usbmuxPort: usbmux.port,
                driverPort: driver.port,
                holderPid: 4040,
                paths: paths
            )
            DriverLifecycleService.processAliveForTesting = { $0 == 8080 }
            DriverLifecycleService.holderLauncherForTesting = { udid, bundleId, _, _ in
                DriverLifecycleService.LaunchMetadata(
                    holderPid: 8080,
                    runnerPid: 9090,
                    sessionIdentifier: "SESSION-NEW",
                    bundleId: bundleId,
                    controlSocketPath: "\(root)/state/new-holder.sock"
                )
            }

            let connectionFile = URL(fileURLWithPath: root).appendingPathComponent("connection.json")
            let connection = RemoteDeviceConnection(
                udid: "REMOTE-RECLAIM",
                driverBundleID: "com.example.driver.xctrunner",
                usbmux: .init(host: "127.0.0.1", port: usbmux.port),
                driver: .init(host: "127.0.0.1", port: driver.port)
            )
            try JSONEncoder().encode(connection).write(to: connectionFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connectionFile.path)

            // Same alias reclaims dead holder lock and starts fresh.
            let output = try RemoteDeviceService.start(connectionPath: connectionFile.path, paths: stale, verbose: false)
            XCTAssertTrue(output.contains("Started remote XCTest Driver for Device phone"))
            let current = try XCTUnwrap(DriverSessionStore.readInfo(paths: stale))
            XCTAssertEqual(current.holderPid, 8080)
            XCTAssertEqual(current.sessionIdentifier, "SESSION-NEW")

            // Starting a second alias for the same UDID still fails.
            let secondAlias = try paths.deviceContext("phone-2")
            XCTAssertThrowsError(try RemoteDeviceService.start(connectionPath: connectionFile.path, paths: secondAlias, verbose: false)) { error in
                XCTAssertTrue(String(describing: error).contains("already running as phone"))
            }
        }
    }

    func testHolderExitLockPolicyPreservesRemoteLockOnlyOnUnexpectedExit() {
        XCTAssertTrue(XCTestSessionHolderService.shouldClearDriverLockOnExit(
            isRemoteConnection: false, interrupted: false, stopRequested: false
        ))
        XCTAssertFalse(XCTestSessionHolderService.shouldClearDriverLockOnExit(
            isRemoteConnection: true, interrupted: false, stopRequested: false
        ))
        XCTAssertTrue(XCTestSessionHolderService.shouldClearDriverLockOnExit(
            isRemoteConnection: true, interrupted: true, stopRequested: false
        ))
        XCTAssertTrue(XCTestSessionHolderService.shouldClearDriverLockOnExit(
            isRemoteConnection: true, interrupted: false, stopRequested: true
        ))
    }

    func testHolderLogTailAppendsRecentLines() throws {
        try withTempHome { _, paths in
            let logPath = CLILogService.holderLogPath(paths: paths)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let content = (1...8).map { "line \($0): holder trace" }.joined(separator: "\n") + "\n\n"
            try content.write(toFile: logPath, atomically: true, encoding: .utf8)

            let rendered = DriverLifecycleService.appendHolderLogTail(
                "XCTest holder exited before start result with status 1.",
                paths: paths
            )

            XCTAssertTrue(rendered.contains("Recent xctest-holder.log:"))
            XCTAssertFalse(rendered.contains("line 1:"))
            XCTAssertFalse(rendered.contains("line 2:"))
            XCTAssertTrue(rendered.contains("line 3: holder trace"))
            XCTAssertTrue(rendered.contains("line 8: holder trace"))
        }
    }

    func testRemoteCoreDevice10002LaunchErrorSuggestsProviderResigning() throws {
        let errorPayload = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: .dictionary([
                "CoreDevice.error": .dictionary([
                    "code": .int64(10002),
                    "domain": .string("com.apple.dt.CoreDeviceError"),
                    "userInfo": .dictionary([
                        "BundleIdentifier": .string("com.example.app"),
                        "NSLocalizedDescription": .string("The application failed to launch."),
                        "NSUnderlyingError": .dictionary([
                            "code": .int64(1),
                            "domain": .string("FBSOpenApplicationServiceErrorDomain"),
                            "userInfo": .dictionary([
                                "NSLocalizedFailureReason": .string("The request was denied by service delegate (SBMainWorkspace)."),
                                "NSUnderlyingError": .dictionary([
                                    "code": .int64(3),
                                    "domain": .string("FBSOpenApplicationErrorDomain"),
                                    "userInfo": .dictionary([
                                        "NSLocalizedFailureReason": .string("Security"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )
        let rootAck = RemoteXPCWrapper.encodeEmpty(messageID: 0, flags: RemoteXPCFlags.alwaysSet)
        let initStream = RemoteXPCHTTP2.settingsFrame()
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: rootAck)
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.replyStreamID, payload: rootAck)
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: rootAck)
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.replyStreamID, payload: errorPayload)

        let stream = InMemoryDeviceStream(reads: [initStream])
        let client = RemoteXPCClient(stream: stream)
        try client.completeClientHandshake()
        let service = CoreDeviceAppService(client: client)
        let connection = RemoteDeviceConnection(
            udid: "REMOTE-10002",
            driverBundleID: "com.example.driver.xctrunner",
            usbmux: .init(host: "127.0.0.1", port: 27015),
            driver: .init(host: "127.0.0.1", port: 8100)
        )

        try RemoteDeviceConnection.$current.withValue(connection) {
            XCTAssertThrowsError(try service.launchApplication(bundleID: "com.example.app")) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("provider's re-signing install"))
                XCTAssertTrue(message.contains("FBSOpenApplicationServiceErrorDomain 1"))
                XCTAssertTrue(message.contains("<- FBSOpenApplicationErrorDomain 3: \"Security\""))
                XCTAssertFalse(message.contains("ios-use config --udid"))
            }
        }
    }

    func testOslogAndMediaImportWorkThroughCLI() throws {
        try withTempHome { root, paths in
            _ = try writeRemoteHolderLock(
                udid: "REMOTE-MEDIA-LOG",
                alias: "phone",
                usbmuxPort: 27015,
                driverPort: 8100,
                holderPid: Int(ProcessInfo.processInfo.processIdentifier),
                paths: paths
            )

            // 1. OSLog packet parsing + CLI execution
            let processPath = Data("/path/DemoApp\0".utf8)
            let imagePath = Data("/usr/lib/libSystem.B.dylib\0".utf8)
            let logMessage = Data("[trace] ping\0".utf8)
            var packet = Data(repeating: 0, count: 129)
            packet[0] = 2
            putUInt32LE(8, into: &packet, at: 1)
            putUInt32LE(129, into: &packet, at: 5)
            putUInt32LE(77, into: &packet, at: 9)
            putUInt16LE(UInt16(processPath.count), into: &packet, at: 37)
            putUInt64LE(1_717_000_000, into: &packet, at: 55)
            putUInt32LE(123, into: &packet, at: 63)
            packet[68] = 0x01
            putUInt16LE(UInt16(imagePath.count), into: &packet, at: 107)
            putUInt32LE(UInt32(logMessage.count), into: &packet, at: 109)
            packet.append(processPath)
            packet.append(imagePath)
            packet.append(logMessage)
            let parsedEvent = try XCTUnwrap(RealDeviceOSTraceService.parseEventPacket(packet))
            XCTAssertEqual(parsedEvent.processName, "DemoApp")

            RealDeviceOSTraceService.collectorForTesting = { udid, timeout, _ in
                XCTAssertEqual(udid, "REMOTE-MEDIA-LOG")
                XCTAssertEqual(timeout, 2)
                return [parsedEvent.rawLine, "Jun 3 13:41:48.000000 Other[1] <Info>: ignore"]
            }

            let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])
            let oslogResult = cli.run(arguments: ["oslog", "-d", "phone", "--pattern", "\\[trace\\] ping", "--timeout", "2"])
            XCTAssertEqual(oslogResult.exitCode, 0)
            XCTAssertTrue(oslogResult.stdout.contains("DemoApp[77] <Info>: [trace] ping"))
            XCTAssertFalse(oslogResult.stdout.contains("Other[1]"))

            // 2. Fallback media extension resolution (Linux path)
            let pngResolved = try MediaImportService.resolveFallbackMediaType(filename: "a.PNG", pathExtension: "PNG")
            XCTAssertEqual(pngResolved.kind, "photo")
            XCTAssertEqual(pngResolved.uniformTypeIdentifier, "public.png")
            let mp4Resolved = try MediaImportService.resolveFallbackMediaType(filename: "clip.mp4", pathExtension: "mp4")
            XCTAssertEqual(mp4Resolved.kind, "video")
            XCTAssertEqual(mp4Resolved.uniformTypeIdentifier, "public.mpeg-4")
            XCTAssertThrowsError(try MediaImportService.resolveFallbackMediaType(filename: "notes.txt", pathExtension: "txt"))

            // 3. Media import CLI human & JSON paths on active remote device
            let photoFile = URL(fileURLWithPath: root).appendingPathComponent("fixture.png")
            let photoBytes = Data([0x89, 0x50, 0x4e, 0x47])
            try photoBytes.write(to: photoFile)
            var receivedArgs: [ForyMediaImportArgs] = []
            DriverCommandExecution.clientFactoryForTesting = { _ in
                RecordingMediaDriverClient { args in
                    receivedArgs.append(args)
                    return ForyMediaImportPayload(
                        kind: args.kind,
                        originalFilename: args.originalFilename,
                        byteCount: args.byteCount,
                        assetLocalIdentifier: "asset/remote-1",
                        permissionPromptHandled: receivedArgs.count == 1
                    )
                }
            }

            let mediaHuman = cli.run(arguments: ["media", "import", "-d", "phone", photoFile.path])
            let mediaJSON = cli.run(arguments: ["media", "import", "-d", "phone", photoFile.path, "--json"])

            XCTAssertEqual(mediaHuman.exitCode, 0)
            XCTAssertEqual(mediaHuman.stdout, "Imported photo fixture.png (4 bytes, asset asset/remote-1)\n")
            XCTAssertEqual(mediaJSON.exitCode, 0)
            XCTAssertTrue(mediaJSON.stdout.contains(#""command" : "media import""#))
            XCTAssertTrue(mediaJSON.stdout.contains(#""assetLocalIdentifier" : "asset/remote-1""#))
            XCTAssertEqual(receivedArgs.count, 2)
            XCTAssertEqual(receivedArgs[0].uniformTypeIdentifier, "public.png")
            XCTAssertEqual(receivedArgs[0].data, photoBytes)
        }
    }

    private func putUInt16LE(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private func putUInt32LE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func putUInt64LE(_ value: UInt64, into data: inout Data, at offset: Int) {
        for shift in 0..<8 {
            data[offset + shift] = UInt8((value >> (shift * 8)) & 0xff)
        }
    }
}

private func makeLoopbackListenerSocket() throws -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, posixStreamSocketType, 0)
    guard fd >= 0 else {
        throw CLIParseError.invalidValue("socket failed: \(errno)")
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    #if os(macOS)
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindOK = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindOK == 0 else {
        _ = posixClose(fd)
        throw CLIParseError.invalidValue("bind failed: \(errno)")
    }
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameOK = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len)
        }
    }
    guard nameOK == 0, listen(fd, 8) == 0 else {
        _ = posixClose(fd)
        throw CLIParseError.invalidValue("listen failed: \(errno)")
    }
    return (fd, Int(UInt16(bigEndian: bound.sin_port)))
}

private func reserveUnusedLocalPort() throws -> Int {
    let listener = try makeLoopbackListenerSocket()
    _ = posixClose(listener.fd)
    return listener.port
}

private final class LoopbackListener {
    let port: Int
    private let listenFD: Int32
    private var stopped = false
    private let lock = NSLock()

    init() throws {
        let listener = try makeLoopbackListenerSocket()
        self.listenFD = listener.fd
        self.port = listener.port
        Thread { [weak self] in self?.acceptLoop() }.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        _ = shutdown(listenFD, Int32(SHUT_RDWR))
        _ = posixClose(listenFD)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            _ = posixClose(client)
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }
        }
    }
}

private final class SwitchableLoopbackForwarder {
    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var _targetPort: Int?

    var targetPort: Int? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _targetPort
        }
        set {
            lock.lock()
            _targetPort = newValue
            lock.unlock()
        }
    }

    init(initialTargetPort: Int?) throws {
        self._targetPort = initialTargetPort
        let listener = try makeLoopbackListenerSocket()
        self.listenFD = listener.fd
        self.port = listener.port
        Thread { [weak self] in self?.acceptLoop() }.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        _ = shutdown(listenFD, Int32(SHUT_RDWR))
        _ = posixClose(listenFD)
    }

    private func acceptLoop() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { return }
            lock.lock()
            let isStopped = stopped
            let upstreamPort = _targetPort
            lock.unlock()
            if isStopped {
                _ = posixClose(clientFD)
                return
            }
            guard let upstreamPort else {
                _ = posixClose(clientFD)
                continue
            }
            Thread { Self.relay(clientFD: clientFD, upstreamPort: upstreamPort) }.start()
        }
    }

    private static func relay(clientFD: Int32, upstreamPort: Int) {
        guard let upstreamFD = try? TCPConnector.connect(host: "127.0.0.1", port: upstreamPort, timeoutSeconds: 2) else {
            _ = posixClose(clientFD)
            return
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            copyBytes(from: clientFD, to: upstreamFD)
            _ = shutdown(upstreamFD, Int32(SHUT_WR))
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            copyBytes(from: upstreamFD, to: clientFD)
            _ = shutdown(clientFD, Int32(SHUT_WR))
            group.leave()
        }
        group.wait()
        _ = posixClose(clientFD)
        _ = posixClose(upstreamFD)
    }

    private static func copyBytes(from sourceFD: Int32, to destFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(sourceFD, raw.baseAddress, raw.count)
            }
            if count <= 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { raw in
                    posixSocketWrite(destFD, raw.baseAddress!.advanced(by: offset), count - offset)
                }
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

private class StubBaseDriverClient: DriverCommandClient {
    func close() {}
    func dom(raw: Bool, waitQuiescence: Bool) throws -> ForyDomPayload { throw CLIParseError.invalidValue("unexpected dom") }
    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload { throw CLIParseError.invalidValue("unexpected waitFor") }
    func screenshot() throws -> Data { throw CLIParseError.invalidValue("unexpected screenshot") }
    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint?) throws -> ForyElementPayload { throw CLIParseError.invalidValue("unexpected tap") }
    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload { throw CLIParseError.invalidValue("unexpected longPress") }
    func input(tap: ForyTarget?, content: String) throws -> ForyElementPayload { throw CLIParseError.invalidValue("unexpected input") }
    func swipe(to: ForyTarget, from: ForyTarget, find: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload { throw CLIParseError.invalidValue("unexpected swipe") }
    func activateApp(bundleId: String) throws { throw CLIParseError.invalidValue("unexpected activateApp") }
    func terminateApp(bundleId: String) throws { throw CLIParseError.invalidValue("unexpected terminateApp") }
    func home() throws { throw CLIParseError.invalidValue("unexpected home") }
    func dismissAlert(args: ForyDismissAlertArgs) throws -> ForyAlertPayload { throw CLIParseError.invalidValue("unexpected dismissAlert") }
    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload { throw CLIParseError.invalidValue("unexpected proxyCAPush") }
    func mediaImport(args: ForyMediaImportArgs) throws -> ForyMediaImportPayload { throw CLIParseError.invalidValue("unexpected mediaImport") }
}

private final class FailingConnectDriverClient: StubBaseDriverClient {
    private let error: Error
    init(error: Error) { self.error = error }
    override func dom(raw: Bool, waitQuiescence: Bool) throws -> ForyDomPayload { throw error }
}

private final class RecordingDomDriverClient: StubBaseDriverClient {
    override func dom(raw: Bool, waitQuiescence: Bool) throws -> ForyDomPayload {
        ForyDomPayload(app: "recovered")
    }
}

private final class RecordingMediaDriverClient: StubBaseDriverClient {
    private let handler: (ForyMediaImportArgs) throws -> ForyMediaImportPayload
    init(handler: @escaping (ForyMediaImportArgs) throws -> ForyMediaImportPayload) {
        self.handler = handler
    }
    override func mediaImport(args: ForyMediaImportArgs) throws -> ForyMediaImportPayload {
        try handler(args)
    }
}

private final class InMemoryDeviceStream: DeviceStream {
    private var buffer: Data
    init(reads: [Data]) {
        self.buffer = reads.reduce(Data(), +)
    }
    func write(_ data: Data) throws {}
    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        guard buffer.count >= byteCount else {
            throw CLIParseError.invalidValue("in-memory stream underflow")
        }
        let out = buffer.prefix(byteCount)
        buffer.removeFirst(byteCount)
        return Data(out)
    }
    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        guard !buffer.isEmpty else { return Data() }
        let count = min(maxBytes, buffer.count)
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }
    func close() {}
}
