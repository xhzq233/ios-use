import Darwin
import Foundation
import IOSUseProtocol

protocol CoreDeviceAppManaging {
    func launchApplication(
        bundleID: String,
        arguments: [String],
        terminateExisting: Bool,
        startSuspended: Bool,
        environment: [String: String],
        payloadURL: String?,
        activates: Bool?
    ) throws -> RemoteXPCValue
    func listProcesses() throws -> [CoreDeviceProcessToken]
    func sendSignal(processIdentifier: Int, signal: Int) throws -> RemoteXPCValue
    func close()
}

extension CoreDeviceAppService: CoreDeviceAppManaging {}

protocol CoreDeviceDriverLifecycleManaging {
    func terminateDriver(udid: String, bundleID: String?) throws -> Bool
}

final class CoreDeviceDriverLifecycle: CoreDeviceDriverLifecycleManaging {
    private static let stopSignalVerificationPolls = 10

    struct Dependencies {
        var startTunnel: (String) throws -> CoreDeviceLifecycleTunnelSession
        var openAppService: (CoreDeviceLifecycleTunnelSession) throws -> CoreDeviceAppManaging
        var isDriverPortReachable: (String) -> Bool
        var sleep: (useconds_t) -> Void

        static let live = live(eventSink: nil)

        static func live(eventSink: ((String) -> Void)?) -> Dependencies {
            Dependencies(
                startTunnel: { try CoreDeviceDirectTunnelRuntime(eventSink: eventSink).start(udid: $0) },
                openAppService: { session in
                    try CoreDeviceAppService(client: session.connectRemoteXPCService(CoreDeviceAppService.serviceName))
                },
                isDriverPortReachable: { udid in
                    guard let fd = try? Usbmux.connect(udid: udid, port: Int(IOSUseProtocol.defaultDriverPort)) else {
                        return false
                    }
                    CoreDeviceDriverLifecycle.closeReadinessProbeSocket(fd)
                    return true
                },
                sleep: { usleep($0) }
            )
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

    func terminateDriver(udid: String, bundleID: String?) throws -> Bool {
        let session = try dependencies.startTunnel(udid)
        defer {
            session.close()
            _ = session.waitForClose(timeoutSeconds: 1)
        }
        guard session.peerInfo != nil else {
            throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
        }
        logPeerInfo(session.peerInfo)
        if let info = session.peerInfo, info.services[CoreDeviceAppService.serviceName] == nil {
            throw CLIParseError.invalidValue("CoreDevice appservice not available on this device. Try re-plugging the device, clearing trust, and re-pairing.")
        }
        eventSink?("opening CoreDevice appservice")
        let appService = try dependencies.openAppService(session)
        defer { appService.close() }

        let processes = try appService.listProcesses()
        eventSink?("CoreDevice listprocesses count=\(processes.count)")
        let samples = processes.prefix(5).map { "\($0.processIdentifier):\($0.executable)" }.joined(separator: ", ")
        if !samples.isEmpty {
            eventSink?("CoreDevice process samples: \(samples)")
        }
        let candidates = Self.driverProcessCandidates(in: processes, bundleID: bundleID)
        eventSink?("CoreDevice matching driver processes=\(candidates.count)")
        guard !candidates.isEmpty else {
            if dependencies.isDriverPortReachable(udid) {
                throw CLIParseError.invalidValue("CoreDevice found no matching driver process but port \(IOSUseProtocol.defaultDriverPort) is still reachable on device \(udid)")
            }
            return false
        }
        for token in candidates {
            do {
                _ = try appService.sendSignal(processIdentifier: token.processIdentifier, signal: Int(SIGKILL))
            } catch CoreDeviceTCPError.connectionClosed {
                if waitUntilDriverPortUnreachable(udid: udid) {
                    eventSink?("CoreDevice sendSignal closed connection after pid=\(token.processIdentifier); driver port is now unreachable")
                    return true
                }
                eventSink?("CoreDevice sendSignal closed connection after pid=\(token.processIdentifier), but driver port is still reachable")
                throw CoreDeviceTCPError.connectionClosed
            } catch {
                eventSink?("CoreDevice sendSignal failed pid=\(token.processIdentifier): \(error)")
                throw error
            }
        }
        if waitUntilDriverPortUnreachable(udid: udid) {
            return true
        }
        throw CLIParseError.invalidValue("CoreDevice sent stop signal but port \(IOSUseProtocol.defaultDriverPort) is still reachable on device \(udid)")
    }

    private func waitUntilDriverPortUnreachable(udid: String) -> Bool {
        for _ in 0..<Self.stopSignalVerificationPolls {
            if !dependencies.isDriverPortReachable(udid) {
                return true
            }
            dependencies.sleep(useconds_t(IOSUseProtocol.driverStartReadinessPollIntervalMicroseconds))
        }
        return false
    }

    private static func closeReadinessProbeSocket(_ fd: Int32) {
        var lingerOption = linger(l_onoff: 1, l_linger: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingerOption, UInt32(MemoryLayout<linger>.size))
        usleep(useconds_t(IOSUseProtocol.driverStartReadinessProbeHoldMicroseconds))
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    static func isDriverProcess(_ token: CoreDeviceProcessToken, bundleID: String?) -> Bool {
        let basename = URL(fileURLWithPath: token.executable).lastPathComponent
        if let bundleID {
            return matchesBundleID(token, bundleID: bundleID)
        }
        if basename == "IOSUseDriver-Runner" {
            return true
        }
        if let bundleIdentifier = token.bundleIdentifier, bundleIdentifier.hasPrefix("com.ios-use.driver.") {
            return true
        }
        return false
    }

    static func driverProcessCandidates(in processes: [CoreDeviceProcessToken], bundleID: String?) -> [CoreDeviceProcessToken] {
        if let bundleID {
            let exact = processes.filter { matchesBundleID($0, bundleID: bundleID) }
            if !exact.isEmpty {
                return exact
            }
            let runners = processes.filter { isRunnerExecutable($0) }
            return runners.count == 1 ? runners : []
        }
        return processes.filter { isDriverProcess($0, bundleID: nil) }
    }

    private static func matchesBundleID(_ token: CoreDeviceProcessToken, bundleID: String) -> Bool {
        if token.bundleIdentifier == bundleID {
            return true
        }
        let normalizedExecutable = token.executable
            .replacingOccurrences(of: "file://", with: "")
            .removingPercentEncoding ?? token.executable
        let components = normalizedExecutable.split(separator: "/").map(String.init)
        return components.contains(bundleID)
    }

    private static func isRunnerExecutable(_ token: CoreDeviceProcessToken) -> Bool {
        URL(fileURLWithPath: token.executable).lastPathComponent == "IOSUseDriver-Runner"
    }

    private func logPeerInfo(_ peerInfo: RemoteXPCPeerInfo?) {
        guard let peerInfo else { return }
        let serviceNames = peerInfo.services.keys.sorted()
        eventSink?("RSD services: \(serviceNames.joined(separator: ", "))")
        if let appService = peerInfo.services[CoreDeviceAppService.serviceName] {
            eventSink?("CoreDevice appservice port=\(appService.port) remoteXPC=\(appService.usesRemoteXPC)")
        }
    }
}
