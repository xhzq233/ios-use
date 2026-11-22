import Foundation
import UIKit
import CoreLocation
import IOSUseProtocol

/// Owned by the model's serial queue. Holds both IDE connections for the whole
/// session. The system XCTest XPC path performs UI work after initialization.
final class SelfRunnerSession {
    private var tunnel: CoreDeviceDirectTunnelSession?
    private var connections = [XCTestManagerSession]()
    private var listeners = [DTXConnectionIdleListener]()
    private var heartbeat: DeviceStream?
    private let heartbeatQueue = DispatchQueue(label: "ios-use.self-runner.heartbeat")
    var log: (String) -> Void = { _ in }

    func start(pairing: Data, host: String) throws {
        let record = try PairRecord.decode(pairing)
        let direct = DirectDeviceConnection(host: host, pairRecord: record, eventSink: log)
        try DirectDeviceConnection.$current.withValue(direct) {
            do {
                log("Connecting local Lockdown")
                let values = try LockdownSession.getValue(udid: "self", key: "ProductVersion")
                guard let version = values["ProductVersion"] as? String,
                      let major = Int(version.split(separator: ".").first ?? ""), major >= 17 else {
                    throw CLIParseError.invalidValue("Could not determine a supported device version")
                }
                log("Lockdown authenticated; iOS \(version)")
                log("Starting developer heartbeat")
                let stream = try LockdownSession.connectToService("com.apple.mobile.heartbeat", udid: "self")
                heartbeat = stream
                heartbeatQueue.async { [weak self] in
                    do {
                        while true {
                            let header = try stream.readExact(byteCount: 4, timeoutSeconds: 30)
                            let count = Int(readUInt32BE(header, 0))
                            guard count > 0, count < 1_048_576 else { throw CLIParseError.invalidValue("Invalid heartbeat frame") }
                            let message = try parsePlist(stream.readExact(byteCount: count, timeoutSeconds: 10))
                            if message["Command"] as? String == "Marco" {
                                let response = try serializePlist(["Command": "Polo"])
                                try stream.write(uint32BE(UInt32(response.count)) + response)
                            }
                        }
                    } catch { self?.log("Heartbeat ended: \(error)") }
                }
                try PersonalizedDDIMounter.ensureMounted(udid: "self", log: log) { identifiers in
                    try RunnerDDIStore.resolve(identifiers: identifiers)
                }
                log("Connecting CoreDevice and RSD")
                let opened = try CoreDeviceDirectTunnelRuntime(eventSink: { [weak self] in self?.log($0) }).start(udid: "self")
                tunnel = opened
                let identifier = UUID()
                setenv("XCTestSessionIdentifier", identifier.uuidString.uppercased(), 1)
                setenv("XCTestManagerVariant", "DDI", 1)
                setenv("XCTestConfigurationFilePath", "", 1)
                for control in [true, false] {
                    let connection = XCTestManagerSession(stream: try opened.connectService(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName))
                    connections.append(connection)
                    try connection.connect()
                    let daemon = try connection.openDaemonConnection()
                    if control { _ = try daemon.initiateControlSession(productMajorVersion: major) }
                    else { try daemon.initiateExecSession(sessionIdentifier: identifier) }
                    if let channel = daemon.channel {
                        let listener = DTXConnectionIdleListener(name: control ? "self-control" : "self-exec", channel: channel, eventSink: log)
                        listeners.append(listener); listener.start()
                    }
                }
                log("Loading XCTest in this process")
                var bootstrapError: NSError?
                guard SRLoadXCTest(&bootstrapError) else { throw bootstrapError ?? NSError(domain: "SelfRunner", code: 1) }
                log("Registering XCTest; accept device automation authorization if requested")
                guard SRInitializeXCTest(&bootstrapError) else { throw bootstrapError ?? NSError(domain: "SelfRunner", code: 2) }
                guard SRLoadRuntime(&bootstrapError) else { throw bootstrapError ?? NSError(domain: "SelfRunner", code: 3) }
                log("Self Runner ready")
            } catch { stop(); throw error }
        }
    }
    func execute(_ command: String, args: [String: Any]) throws -> [String: Any] {
        guard tunnel != nil else { throw CLIParseError.invalidValue("Start the automation session first") }
        var result: Result<[String: Any], Error>!
        DispatchQueue.main.sync {
            result = Result {
                var error: NSError?
                guard let dictionary = SRExecute(command, args, &error) as? [String: Any] else {
                    if let error { throw error }
                    throw CLIParseError.invalidValue("Automation runtime returned no result")
                }
                return dictionary
            }
        }
        return try result.get()
    }
    func stop() {
        SRStopAutomation()
        listeners.forEach { $0.stop() }; listeners.removeAll()
        connections.forEach { $0.close() }; connections.removeAll()
        heartbeat?.close(); heartbeat = nil
        tunnel?.close()
        _ = tunnel?.waitForClose(timeoutSeconds: 3)
        tunnel = nil
        log("Session stopped")
    }
    deinit { stop() }
}

@MainActor final class BackgroundSession: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }
    func start() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }
    func stop() { manager.stopUpdatingLocation() }
}
