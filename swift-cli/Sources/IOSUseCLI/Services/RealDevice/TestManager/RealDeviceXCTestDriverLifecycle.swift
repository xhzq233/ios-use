import Darwin
import Foundation
import IOSUseProtocol

struct XCTestRunnerInstallInfo: Equatable {
    let appPath: String
    let testBundlePath: String
}

protocol XCTestRunnerAppServicing: AnyObject {
    func launchXCTestRunner(
        bundleID: String,
        arguments: [String],
        environment: [String: String],
        standardIOIdentifier: UUID?
    ) throws -> Int
    func kill(processIdentifier: Int) throws
    func close()
}

extension CoreDeviceAppService: XCTestRunnerAppServicing {}

final class RealDeviceXCTestActiveSession {
    let sessionIdentifier: UUID
    let runnerPid: Int

    private let appService: XCTestRunnerAppServicing
    private let stdioSocket: CoreDeviceOpenStdIOSocket?
    private let listener: XCTestExecCallbackListener
    private let controlListener: DTXConnectionIdleListener?
    private let execSession: XCTestManagerSession
    private let controlSession: XCTestManagerSession
    private let primaryTunnel: CoreDeviceLifecycleTunnelSession
    private let tunnels: [CoreDeviceLifecycleTunnelSession]
    private let eventSink: ((String) -> Void)?
    private let lock = NSLock()
    private let displayInfoLock = NSLock()
    private var closed = false

    init(
        sessionIdentifier: UUID,
        runnerPid: Int,
        appService: XCTestRunnerAppServicing,
        stdioSocket: CoreDeviceOpenStdIOSocket?,
        listener: XCTestExecCallbackListener,
        controlListener: DTXConnectionIdleListener?,
        execSession: XCTestManagerSession,
        controlSession: XCTestManagerSession,
        primaryTunnel: CoreDeviceLifecycleTunnelSession,
        tunnels: [CoreDeviceLifecycleTunnelSession],
        eventSink: ((String) -> Void)?
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.runnerPid = runnerPid
        self.appService = appService
        self.stdioSocket = stdioSocket
        self.listener = listener
        self.controlListener = controlListener
        self.execSession = execSession
        self.controlSession = controlSession
        self.primaryTunnel = primaryTunnel
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
            try? appService.kill(processIdentifier: runnerPid)
        } else {
            eventSink?("closing XCTest session; leaving runner pid=\(runnerPid)")
        }
        stdioSocket?.close()
        controlListener?.stop()
        listener.stop()
        controlSession.close()
        execSession.close()
        appService.close()
        // Do not tear down the shared tunnel while a best-effort Display Info
        // request is still using it.
        displayInfoLock.lock()
        for tunnel in tunnels {
            tunnel.close()
        }
        for tunnel in tunnels {
            _ = tunnel.waitForClose(timeoutSeconds: IOSUseProtocol.XCConstants.xctestTunnelCloseTimeoutSeconds)
        }
        displayInfoLock.unlock()
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

    func getDisplayInfo() throws -> CoreDeviceDisplayInfo {
        displayInfoLock.lock()
        defer { displayInfoLock.unlock() }

        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else {
            throw CLIParseError.invalidValue("XCTest holder session is closed")
        }

        guard primaryTunnel.peerInfo?.services[CoreDeviceDisplayInfoService.serviceName] != nil else {
            throw CLIParseError.invalidValue("CoreDevice deviceinfo service is not available")
        }
        // deviceinfo closes its RemoteXPC stream after replying. Reuse the
        // long-lived CoreDevice tunnel, but open a fresh service connection for
        // each query so consecutive screenshots do not alternate success/failure.
        eventSink?("opening CoreDevice deviceinfo service")
        let service = CoreDeviceDisplayInfoService(
            client: try primaryTunnel.connectRemoteXPCService(
                CoreDeviceDisplayInfoService.serviceName,
                routeLabel: "deviceinfo"
            )
        )
        defer { service.close() }
        return try service.getDisplayInfo()
    }

    deinit {
        close(killRunner: false)
    }
}

final class RealDeviceXCTestDriverLifecycle {
    struct IOSProductVersion: Comparable, CustomStringConvertible {
        let major: Int
        let minor: Int
        let patch: Int
        let rawValue: String

        var description: String { rawValue }

        init(_ rawValue: String) throws {
            let parts = rawValue.split(separator: ".")
            guard let majorPart = parts.first,
                  let major = Int(majorPart) else {
                throw CLIParseError.invalidValue("Unable to parse iOS ProductVersion: \(rawValue)")
            }
            self.major = major
            self.minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            self.patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            self.rawValue = rawValue
        }

        static func < (lhs: IOSProductVersion, rhs: IOSProductVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    struct Dependencies {
        var startTunnel: (String) throws -> CoreDeviceLifecycleTunnelSession
        var resolveRunnerInfo: (String, String) throws -> XCTestRunnerInstallInfo
        var productVersion: (String) throws -> String
        var makeSessionIdentifier: () -> UUID
        var openAppService: (CoreDeviceLifecycleTunnelSession) throws -> XCTestRunnerAppServicing
        var openStdIOSocket: (CoreDeviceLifecycleTunnelSession) throws -> CoreDeviceOpenStdIOSocket

        static let live = live(eventSink: nil)

        static func live(eventSink: ((String) -> Void)?) -> Dependencies {
            Dependencies(
                startTunnel: { try CoreDeviceDirectTunnelRuntime(eventSink: eventSink).start(udid: $0) },
                resolveRunnerInfo: { udid, bundleID in
                    try Self.installedRunnerInfo(udid: udid, bundleID: bundleID)
                },
                productVersion: { udid in
                    let values = try LockdownSession.getValue(udid: udid, key: "ProductVersion")
                    guard let version = values["ProductVersion"] as? String, !version.isEmpty else {
                        throw CLIParseError.invalidValue("Unable to determine ProductVersion for device \(udid)")
                    }
                    return version
                },
                makeSessionIdentifier: { UUID() },
                openAppService: { session in
                    CoreDeviceAppService(client: try session.connectRemoteXPCService(CoreDeviceAppService.serviceName))
                },
                openStdIOSocket: { session in
                    try CoreDeviceOpenStdIOSocket.connect(session: session)
                }
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

    func startDriverSession(udid: String, bundleID: String) throws -> RealDeviceXCTestActiveSession {
        let productVersion = try IOSProductVersion(dependencies.productVersion(udid))
        eventSink?("testmanagerd product version=\(productVersion)")
        let minimumVersion = try IOSProductVersion(IOSUseProtocol.XCConstants.minimumRealDeviceIOSVersion)
        guard productVersion >= minimumVersion else {
            throw CLIParseError.invalidValue("Real-device start requires iOS \(IOSUseProtocol.XCConstants.minimumRealDeviceIOSVersion) or later; device \(udid) reported iOS \(productVersion).")
        }
        let productMajorVersion = productVersion.major
        let runnerInfo = try dependencies.resolveRunnerInfo(udid, bundleID)
        eventSink?("resolved runner app=\(runnerInfo.appPath)")
        eventSink?("resolved test bundle=\(runnerInfo.testBundlePath)")

        var launchedPid: Int?
        var appService: XCTestRunnerAppServicing?
        var stdioSocket: CoreDeviceOpenStdIOSocket?
        var listener: XCTestExecCallbackListener?
        var controlListener: DTXConnectionIdleListener?
        var execSession: XCTestManagerSession?
        var controlSession: XCTestManagerSession?
        var coreDeviceTunnel: CoreDeviceLifecycleTunnelSession?
        do {
            let openedTunnel = try startValidatedTunnel(
                udid: udid,
                requiredServices: [
                    DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName,
                    CoreDeviceAppService.serviceName,
                    CoreDeviceOpenStdIOSocket.serviceName,
                ],
                logPeerInfo: true
            )
            coreDeviceTunnel = openedTunnel

            let sessionIdentifier = dependencies.makeSessionIdentifier()
            eventSink?("opening CoreDevice AppService")
            let openedAppService = try dependencies.openAppService(openedTunnel)
            appService = openedAppService

            eventSink?("opening CoreDevice openstdio socket")
            let openedStdIOSocket = try dependencies.openStdIOSocket(openedTunnel)
            stdioSocket = openedStdIOSocket
            openedStdIOSocket.startDraining(eventSink: eventSink)

            eventSink?("opening XCTest exec session")
            let openedExecSession = XCTestManagerSession(
                stream: try openedTunnel.connectService(
                    DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName,
                    routeLabel: "xctest-exec"
                )
            )
            execSession = openedExecSession
            try openedExecSession.connect()
            let execDaemon = try openedExecSession.openDaemonConnection()
            guard let execChannel = execDaemon.channel else {
                throw CLIParseError.invalidValue("XCTest exec daemon channel was not available")
            }

            eventSink?("initiating XCTest exec session id=\(sessionIdentifier.uuidString)")
            try execDaemon.initiateExecSession(sessionIdentifier: sessionIdentifier)

            let environment = Self.launchEnvironment(
                testBundlePath: runnerInfo.testBundlePath,
                sessionIdentifier: sessionIdentifier
            )
            eventSink?("launching XCTest runner through CoreDevice AppService")
            let pid = try openedAppService.launchXCTestRunner(
                bundleID: bundleID,
                arguments: [],
                environment: environment,
                standardIOIdentifier: openedStdIOSocket.identifier
            )
            launchedPid = pid
            eventSink?("AppService launched runner pid=\(pid)")

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

            eventSink?("opening XCTest control session")
            let openedControlSession = XCTestManagerSession(
                stream: try openedTunnel.connectService(
                    DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName,
                    routeLabel: "xctest-control"
                )
            )
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
            try openedListener.waitUntilConfigurationSent(timeoutSeconds: IOSUseProtocol.XCConstants.xctestRunnerConfigurationTimeoutSeconds)
            eventSink?("starting XCTest test plan")
            try execDaemon.startExecutingTestPlan()

            guard let appService,
                  let listener,
                  let execSession,
                  let controlSession,
                  let coreDeviceTunnel else {
                throw CLIParseError.invalidValue("XCTest active session was incomplete after launch")
            }
            return RealDeviceXCTestActiveSession(
                sessionIdentifier: sessionIdentifier,
                runnerPid: pid,
                appService: appService,
                stdioSocket: stdioSocket,
                listener: listener,
                controlListener: controlListener,
                execSession: execSession,
                controlSession: controlSession,
                primaryTunnel: coreDeviceTunnel,
                tunnels: [coreDeviceTunnel],
                eventSink: eventSink
            )
        } catch {
            if let pid = launchedPid {
                eventSink?("XCTest start failed; cleaning launched pid=\(pid)")
                try? appService?.kill(processIdentifier: pid)
            }
            stdioSocket?.close()
            listener?.stop()
            controlListener?.stop()
            controlSession?.close()
            execSession?.close()
            appService?.close()
            let openedTunnels = [coreDeviceTunnel].compactMap { $0 }
            for tunnel in openedTunnels {
                tunnel.close()
            }
            for tunnel in openedTunnels {
                _ = tunnel.waitForClose(timeoutSeconds: IOSUseProtocol.XCConstants.xctestTunnelCloseTimeoutSeconds)
            }
            throw error
        }
    }

    private func validateRequiredServices(_ serviceNames: [String], peerInfo: RemoteXPCPeerInfo, udid: String) throws {
        for serviceName in serviceNames {
            do {
                _ = try peerInfo.servicePort(serviceName)
            } catch {
                if serviceName == DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName,
                   String(describing: error).contains("Services.\(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName)") {
                    throw CLIParseError.invalidValue(
                        "Developer Disk Image services are not ready on \(udid). Run `ios-use ddi-mount --udid \(udid)` and retry `ios-use start`. Original error: \(error)"
                    )
                }
                throw error
            }
        }
    }

    private func startValidatedTunnel(
        udid: String,
        requiredServices: [String],
        logPeerInfo shouldLogPeerInfo: Bool
    ) throws -> CoreDeviceLifecycleTunnelSession {
        let tunnel = try dependencies.startTunnel(udid)
        do {
            guard let peerInfo = tunnel.peerInfo else {
                throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
            }
            if shouldLogPeerInfo {
                logPeerInfo(peerInfo)
            }
            try validateRequiredServices(requiredServices, peerInfo: peerInfo, udid: udid)
            return tunnel
        } catch {
            tunnel.close()
            _ = tunnel.waitForClose(timeoutSeconds: IOSUseProtocol.XCConstants.xctestTunnelCloseTimeoutSeconds)
            throw error
        }
    }

    private func logPeerInfo(_ peerInfo: RemoteXPCPeerInfo) {
        let serviceNames = peerInfo.services.keys.sorted()
        eventSink?("RSD services: \(serviceNames.joined(separator: ", "))")
        if let testmanager = peerInfo.services[DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName] {
            eventSink?("testmanagerd port=\(testmanager.port)")
        }
        if let appservice = peerInfo.services[CoreDeviceAppService.serviceName] {
            eventSink?("appservice port=\(appservice.port)")
        }
        if let openstdio = peerInfo.services[CoreDeviceOpenStdIOSocket.serviceName] {
            eventSink?("openstdio port=\(openstdio.port)")
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

}
