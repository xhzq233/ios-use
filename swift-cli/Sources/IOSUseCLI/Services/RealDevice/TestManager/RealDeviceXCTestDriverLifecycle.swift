import Darwin
import Foundation
import IOSUseProtocol

struct XCTestRunnerInstallInfo: Equatable {
    let appPath: String
    let testBundlePath: String
}

final class RealDeviceXCTestActiveSession {
    let sessionIdentifier: UUID
    let runnerPid: Int

    private let processControl: DVTProcessControlClient
    private let listener: XCTestExecCallbackListener
    private let controlListener: DTXConnectionIdleListener?
    private let execSession: XCTestManagerSession
    private let instrumentsSession: DVTInstrumentsSession
    private let controlSession: XCTestManagerSession
    private let tunnels: [CoreDeviceLifecycleTunnelSession]
    private let eventSink: ((String) -> Void)?
    private let lock = NSLock()
    private var closed = false

    init(
        sessionIdentifier: UUID,
        runnerPid: Int,
        processControl: DVTProcessControlClient,
        listener: XCTestExecCallbackListener,
        controlListener: DTXConnectionIdleListener?,
        execSession: XCTestManagerSession,
        instrumentsSession: DVTInstrumentsSession,
        controlSession: XCTestManagerSession,
        tunnels: [CoreDeviceLifecycleTunnelSession],
        eventSink: ((String) -> Void)?
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.runnerPid = runnerPid
        self.processControl = processControl
        self.listener = listener
        self.controlListener = controlListener
        self.execSession = execSession
        self.instrumentsSession = instrumentsSession
        self.controlSession = controlSession
        self.tunnels = tunnels
        self.eventSink = eventSink
    }

    func close(killRunner: Bool) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        if killRunner {
            eventSink?("closing XCTest session; killing runner pid=\(runnerPid)")
            try? processControl.kill(pid: runnerPid)
        } else {
            eventSink?("closing XCTest session; leaving runner pid=\(runnerPid)")
        }
        controlListener?.stop()
        listener.stop()
        controlSession.close()
        execSession.close()
        instrumentsSession.close()
        for tunnel in tunnels {
            tunnel.close()
        }
        for tunnel in tunnels {
            _ = tunnel.waitForClose(timeoutSeconds: 1)
        }
    }

    var startupFailure: Error? {
        listener.startupFailure
    }

    func takePostConfigurationFailure() -> Error? {
        if let failure = listener.takePostConfigurationFailure() {
            return failure
        }
        if let failure = controlListener?.takeFailure() {
            return failure
        }
        return nil
    }

    deinit {
        close(killRunner: false)
    }
}

final class RealDeviceXCTestDriverLifecycle {
    struct Dependencies {
        var startTunnel: (String) throws -> CoreDeviceLifecycleTunnelSession
        var resolveRunnerInfo: (String, String) throws -> XCTestRunnerInstallInfo
        var productMajorVersion: (String) throws -> Int
        var makeSessionIdentifier: () -> UUID
        var isDriverPortReachable: (String) -> Bool
        var sleep: (useconds_t) -> Void

        static let live = live(eventSink: nil)

        static func live(eventSink: ((String) -> Void)?) -> Dependencies {
            Dependencies(
                startTunnel: { try CoreDeviceDirectTunnelRuntime(eventSink: eventSink).start(udid: $0) },
                resolveRunnerInfo: { udid, bundleID in
                    try Self.installedRunnerInfo(udid: udid, bundleID: bundleID)
                },
                productMajorVersion: { udid in
                    let values = try LockdownSession.getValue(udid: udid, key: "ProductVersion")
                    guard let version = values["ProductVersion"] as? String,
                          let major = Int(version.split(separator: ".").first ?? "") else {
                        throw CLIParseError.invalidValue("Unable to determine ProductVersion for device \(udid)")
                    }
                    return major
                },
                makeSessionIdentifier: { UUID() },
                isDriverPortReachable: { udid in
                    guard let fd = try? Usbmux.connect(udid: udid, port: Int(IOSUseProtocol.defaultDriverPort)) else {
                        return false
                    }
                    RealDeviceXCTestDriverLifecycle.closeReadinessProbeSocket(fd)
                    return true
                },
                sleep: { usleep($0) }
            )
        }

        private static func installedRunnerInfo(udid: String, bundleID: String) throws -> XCTestRunnerInstallInfo {
            let attributes = ["CFBundleIdentifier", "Path", "CFBundleExecutable"]
            guard let info = try InstallationProxyClient.withClient(udid: udid, { client in
                try client.installedAppInfo(bundleID: bundleID, attributes: attributes)
            }) else {
                throw CLIParseError.invalidValue("Installed driver \(bundleID) was not found on device \(udid). Run `ios-use config --udid \(udid)` first.")
            }
            guard let rawPath = info["Path"] as? String, !rawPath.isEmpty else {
                throw CLIParseError.invalidValue("Installed driver \(bundleID) did not report application Path; response: \(InstallationProxyClient.responseSummary(info))")
            }
            let appPath = normalizeDevicePath(rawPath)
            return XCTestRunnerInstallInfo(
                appPath: appPath,
                testBundlePath: "\(appPath)/PlugIns/IOSUseDriver.xctest"
            )
        }

        private static func normalizeDevicePath(_ path: String) -> String {
            (path.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? path)
        }
    }

    private let dependencies: Dependencies
    private let eventSink: ((String) -> Void)?

    init(dependencies: Dependencies = .live, eventSink: ((String) -> Void)? = nil) {
        self.dependencies = dependencies
        self.eventSink = eventSink
    }

    convenience init(eventSink: ((String) -> Void)?) {
        self.init(dependencies: .live(eventSink: eventSink), eventSink: eventSink)
    }

    func startDriverSession(udid: String, bundleID: String, timeoutSeconds: Double = 30) throws -> RealDeviceXCTestActiveSession {
        let productMajorVersion = try dependencies.productMajorVersion(udid)
        eventSink?("testmanagerd product major version=\(productMajorVersion)")
        guard productMajorVersion >= 17 else {
            throw CLIParseError.invalidValue("Real-device start requires iOS 17 or later; device \(udid) reported iOS \(productMajorVersion).")
        }
        let runnerInfo = try dependencies.resolveRunnerInfo(udid, bundleID)
        eventSink?("resolved runner app=\(runnerInfo.appPath)")
        eventSink?("resolved test bundle=\(runnerInfo.testBundlePath)")

        var launchedPid: Int?
        var processControl: DVTProcessControlClient?
        var listener: XCTestExecCallbackListener?
        var controlListener: DTXConnectionIdleListener?
        var execSession: XCTestManagerSession?
        var instrumentsSession: DVTInstrumentsSession?
        var controlSession: XCTestManagerSession?
        var execTunnel: CoreDeviceLifecycleTunnelSession?
        var processTunnel: CoreDeviceLifecycleTunnelSession?
        var controlTunnel: CoreDeviceLifecycleTunnelSession?
        do {
            let openedExecTunnel = try startValidatedTunnel(udid: udid, logPeerInfo: true)
            execTunnel = openedExecTunnel

            eventSink?("opening XCTest exec session")
            let openedExecSession = XCTestManagerSession(stream: try openedExecTunnel.connectService(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName))
            execSession = openedExecSession
            try openedExecSession.connect()
            let execDaemon = try openedExecSession.openDaemonConnection()
            guard let execChannel = execDaemon.channel else {
                throw CLIParseError.invalidValue("XCTest exec daemon channel was not available")
            }

            let sessionIdentifier = dependencies.makeSessionIdentifier()
            eventSink?("initiating XCTest exec session id=\(sessionIdentifier.uuidString)")
            try execDaemon.initiateExecSession(sessionIdentifier: sessionIdentifier)

            let openedProcessTunnel = try startValidatedTunnel(udid: udid, logPeerInfo: false)
            processTunnel = openedProcessTunnel

            eventSink?("opening DVT ProcessControl")
            let openedInstrumentsSession = DVTInstrumentsSession(stream: try openedProcessTunnel.connectService(DVTInstrumentsContract.Provider.rsdServiceName))
            instrumentsSession = openedInstrumentsSession
            try openedInstrumentsSession.connect()
            processControl = try openedInstrumentsSession.openProcessControl()

            let environment = Self.launchEnvironment(
                testBundlePath: runnerInfo.testBundlePath,
                sessionIdentifier: sessionIdentifier
            )
            eventSink?("launching XCTest runner through DVT ProcessControl")
            let pid = abs(try processControl!.launch(
                bundleID: bundleID,
                environment: environment,
                arguments: [],
                killExisting: true,
                startSuspended: false
            ))
            launchedPid = pid
            eventSink?("ProcessControl launched runner pid=\(pid)")

            let configuration = try XCTestConfigurationPayload(
                testBundlePath: runnerInfo.testBundlePath,
                sessionIdentifier: sessionIdentifier
            ).encode()
            let openedListener = XCTestExecCallbackListener(
                channel: execChannel,
                configurationPayload: configuration,
                eventSink: eventSink
            )
            listener = openedListener
            openedListener.start()

            let openedControlTunnel = try startValidatedTunnel(udid: udid, logPeerInfo: false)
            controlTunnel = openedControlTunnel

            eventSink?("opening XCTest control session")
            let openedControlSession = XCTestManagerSession(stream: try openedControlTunnel.connectService(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName))
            controlSession = openedControlSession
            try openedControlSession.connect()
            let controlDaemon = try openedControlSession.openDaemonConnection()
            eventSink?("initiating XCTest control session")
            _ = try controlDaemon.initiateControlSession(productMajorVersion: productMajorVersion)
            eventSink?("authorizing XCTest runner pid=\(pid)")
            guard try controlDaemon.authorizeTestSession(productMajorVersion: productMajorVersion, pid: pid) else {
                throw CLIParseError.invalidValue("testmanagerd authorization returned false for pid \(pid)")
            }
            guard let controlChannel = controlDaemon.channel else {
                throw CLIParseError.invalidValue("XCTest control daemon channel was not available")
            }
            let openedControlListener = DTXConnectionIdleListener(
                name: "xctest-control",
                channel: controlChannel,
                eventSink: eventSink
            )
            controlListener = openedControlListener
            openedControlListener.start()

            eventSink?("waiting for XCTest runner ready/configuration reply")
            try openedListener.waitUntilConfigurationSent(timeoutSeconds: 20)
            eventSink?("starting XCTest test plan")
            try execDaemon.startExecutingTestPlan()

            try waitForDriverReadiness(udid: udid, timeoutSeconds: timeoutSeconds)
            eventSink?("driver port became reachable")
            guard let processControl,
                  let listener,
                  let execSession,
                  let instrumentsSession,
                  let controlSession,
                  let execTunnel,
                  let processTunnel,
                  let controlTunnel else {
                throw CLIParseError.invalidValue("XCTest active session was incomplete after launch")
            }
            return RealDeviceXCTestActiveSession(
                sessionIdentifier: sessionIdentifier,
                runnerPid: pid,
                processControl: processControl,
                listener: listener,
                controlListener: controlListener,
                execSession: execSession,
                instrumentsSession: instrumentsSession,
                controlSession: controlSession,
                tunnels: [execTunnel, processTunnel, controlTunnel],
                eventSink: eventSink
            )
        } catch {
            if let pid = launchedPid {
                eventSink?("XCTest start failed; cleaning launched pid=\(pid)")
                try? processControl?.kill(pid: pid)
                _ = waitUntilDriverPortUnreachable(udid: udid)
            }
            listener?.stop()
            controlListener?.stop()
            controlSession?.close()
            execSession?.close()
            instrumentsSession?.close()
            for tunnel in [execTunnel, processTunnel, controlTunnel].compactMap({ $0 }) {
                tunnel.close()
            }
            for tunnel in [execTunnel, processTunnel, controlTunnel].compactMap({ $0 }) {
                _ = tunnel.waitForClose(timeoutSeconds: 1)
            }
            throw error
        }
    }

    private func validateRequiredServices(_ peerInfo: RemoteXPCPeerInfo) throws {
        _ = try peerInfo.servicePort(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName)
        _ = try peerInfo.servicePort(DVTInstrumentsContract.Provider.rsdServiceName)
    }

    private func startValidatedTunnel(udid: String, logPeerInfo shouldLogPeerInfo: Bool) throws -> CoreDeviceLifecycleTunnelSession {
        let tunnel = try dependencies.startTunnel(udid)
        do {
            guard let peerInfo = tunnel.peerInfo else {
                throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
            }
            if shouldLogPeerInfo {
                logPeerInfo(peerInfo)
            }
            try validateRequiredServices(peerInfo)
            return tunnel
        } catch {
            tunnel.close()
            _ = tunnel.waitForClose(timeoutSeconds: 1)
            throw error
        }
    }

    private func waitForDriverReadiness(udid: String, timeoutSeconds: Double) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        dependencies.sleep(useconds_t(IOSUseProtocol.driverStartReadinessInitialDelayMicroseconds))
        while Date() < deadline {
            if dependencies.isDriverPortReachable(udid) {
                return
            }
            dependencies.sleep(useconds_t(IOSUseProtocol.driverStartReadinessPollIntervalMicroseconds))
        }
        throw CLIParseError.invalidValue("XCTest started driver but port \(IOSUseProtocol.defaultDriverPort) did not become reachable on device \(udid)")
    }

    private func waitUntilDriverPortUnreachable(udid: String) -> Bool {
        for _ in 0..<10 {
            if !dependencies.isDriverPortReachable(udid) {
                return true
            }
            dependencies.sleep(useconds_t(IOSUseProtocol.driverStartReadinessPollIntervalMicroseconds))
        }
        return false
    }

    private func logPeerInfo(_ peerInfo: RemoteXPCPeerInfo) {
        let serviceNames = peerInfo.services.keys.sorted()
        eventSink?("RSD services: \(serviceNames.joined(separator: ", "))")
        if let testmanager = peerInfo.services[DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName] {
            eventSink?("testmanagerd port=\(testmanager.port)")
        }
        if let instruments = peerInfo.services[DVTInstrumentsContract.Provider.rsdServiceName] {
            eventSink?("instruments dtservicehub port=\(instruments.port)")
        }
    }

    private static func launchEnvironment(testBundlePath: String, sessionIdentifier: UUID) -> [String: String] {
        [
            "CA_ASSERT_MAIN_THREAD_TRANSACTIONS": "0",
            "CA_DEBUG_TRANSACTIONS": "0",
            "DYLD_INSERT_LIBRARIES": "/Developer/usr/lib/libMainThreadChecker.dylib",
            "DYLD_FRAMEWORK_PATH": "/System/Developer/Library/Frameworks",
            "DYLD_LIBRARY_PATH": "/System/Developer/usr/lib",
            "MTC_CRASH_ON_REPORT": "1",
            "NSUnbufferedIO": "YES",
            "OS_ACTIVITY_DT_MODE": "YES",
            "SQLITE_ENABLE_THREAD_ASSERTIONS": "1",
            "XCTestBundlePath": testBundlePath,
            "XCTestConfigurationFilePath": "",
            "XCTestManagerVariant": "DDI",
            "XCTestSessionIdentifier": sessionIdentifier.uuidString.uppercased(),
        ]
    }

    private static func closeReadinessProbeSocket(_ fd: Int32) {
        var lingerOption = linger(l_onoff: 1, l_linger: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingerOption, UInt32(MemoryLayout<linger>.size))
        usleep(useconds_t(IOSUseProtocol.driverStartReadinessProbeHoldMicroseconds))
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
