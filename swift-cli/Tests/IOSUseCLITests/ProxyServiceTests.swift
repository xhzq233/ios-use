import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class ProxyServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        ProxyService.mitmdumpReadOverrideForTesting = nil
        ProxyService.startMitmdumpOverrideForTesting = nil
        ProxyService.detectLanInfoOverrideForTesting = nil
        ProxyService.flowDirectoryOverrideForTesting = nil
        Shell.runOverrideForTesting = nil
        super.tearDown()
    }

    func testProxyTargetComesFromActiveDriverLockNotStaleProxyState() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try writeDriverLock(udid: "LOCK-DEVICE", paths: paths)
        let stale = ProxySessionState(
            sessionId: "proxy-old",
            status: "stopped",
            startedAt: 1,
            udid: "STALE-PROXY-DEVICE",
            flowFile: "old.flow"
        )
        let data = try JSONEncoder().encode(stale)
        try data.write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))

        XCTAssertEqual(try ProxyService.activeUdidForTesting(paths: paths), "LOCK-DEVICE")
    }

    func testProxyStartWithoutDriverLockFailsBeforeDeviceDiscovery() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("proxy start without driver.lock must not discover devices")
            return []
        }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
        }

        XCTAssertThrowsError(try ProxyService.start(interfaceName: nil, paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("ios-use start <UDID>"))
        }
    }

    func testProxyStartServerOnlyDoesNotRequireDriverLockAndWritesLastCapture() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/mitmproxy", withIntermediateDirectories: true)
        try "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n".write(
            toFile: "\(root)/mitmproxy/mitmproxy-ca-cert.pem",
            atomically: true,
            encoding: .utf8
        )
        ProxyService.detectLanInfoOverrideForTesting = { interfaceName in
            XCTAssertNil(interfaceName)
            return ProxySessionState.NetworkInfo(interface: "en0", macLanIp: "192.168.1.10")
        }
        ProxyService.startMitmdumpOverrideForTesting = { flowFile, _ in
            XCTAssertTrue(flowFile.hasPrefix("\(root)/artifacts/proxy-"))
            return 321
        }

        let output = try ProxyService.start(interfaceName: nil, serverOnly: true, paths: paths)

        XCTAssertTrue(output.contains("Proxy server started"))
        XCTAssertTrue(output.contains("Device Wi-Fi proxy was not configured"))
        let state = try XCTUnwrap(ProxyService.readState(paths: paths))
        XCTAssertEqual(state.status, "running")
        XCTAssertEqual(state.serverStatus, "running")
        XCTAssertEqual(state.deviceProxyStatus, "unknown")
        XCTAssertEqual(state.udid, "")
        XCTAssertEqual(state.mitmdumpPid, 321)
        XCTAssertEqual(state.mitmdumpPort, IOSUseProtocol.proxyMitmdumpPort)
        XCTAssertEqual(state.lastCapture?.flowFile, state.flowFile)
    }

    func testProxyStartPrefersExecutableFlowDirectoryOverHomeCopy() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let preferredFlowDirectory = "\(root)/preferred-flows"
        try FileManager.default.createDirectory(atPath: "\(root)/mitmproxy", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/flows", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: preferredFlowDirectory, withIntermediateDirectories: true)
        try "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n".write(
            toFile: "\(root)/mitmproxy/mitmproxy-ca-cert.pem",
            atomically: true,
            encoding: .utf8
        )
        try """
        name: stale proxy flow
        steps:
          - action: unknown
        """.write(toFile: "\(root)/flows/proxy_set_wifi_proxy.yaml", atomically: true, encoding: .utf8)
        try """
        name: preferred proxy flow
        steps:
          - action: sleep
            ms: 1
        """.write(toFile: "\(preferredFlowDirectory)/proxy_set_wifi_proxy.yaml", atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "DEVICE-A", paths: paths)
        ProxyService.flowDirectoryOverrideForTesting = preferredFlowDirectory
        ProxyService.detectLanInfoOverrideForTesting = { _ in
            ProxySessionState.NetworkInfo(interface: "en0", macLanIp: "192.168.1.10")
        }
        ProxyService.startMitmdumpOverrideForTesting = { _, _ in 321 }

        let output = try ProxyService.start(interfaceName: nil, paths: paths)

        XCTAssertTrue(output.contains("Proxy started"))
        let state = try XCTUnwrap(ProxyService.readState(paths: paths))
        XCTAssertEqual(state.deviceProxyStatus, "configured")
    }

    func testProxyConfigCAWithoutDriverLockFailsBeforeCAWork() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])

        XCTAssertThrowsError(try ProxyService.configCA(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("ios-use start <UDID>"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/mitmproxy/mitmproxy-ca-cert.pem"))
    }

    func testProxyStopWithoutDriverLockFailsBeforeStateCleanup() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        let statePath = "\(root)/state/proxy-session.json"
        let state = ProxySessionState(
            sessionId: "proxy-running",
            status: "running",
            startedAt: 1,
            udid: "DEVICE-A",
            flowFile: "capture.flow"
        )
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: statePath))

        XCTAssertThrowsError(try ProxyService.stop(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("ios-use start <UDID>"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: statePath))
    }

    func testProxyStopRejectsStateForDifferentActiveDriver() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try writeDriverLock(udid: "DEVICE-B", paths: paths)
        let state = ProxySessionState(
            sessionId: "proxy-running",
            status: "running",
            startedAt: 1,
            udid: "DEVICE-A",
            flowFile: "capture.flow"
        )
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))

        XCTAssertThrowsError(try ProxyService.stop(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("running for DEVICE-A"))
        }
    }

    func testProxyStopRejectsStoppedStateBeforeClearingDeviceProxy() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try writeDriverLock(udid: "DEVICE-A", paths: paths)
        let state = ProxySessionState(
            sessionId: "proxy-stopped",
            status: "stopped",
            startedAt: 1,
            stoppedAt: 2,
            udid: "DEVICE-A",
            flowFile: "capture.flow"
        )
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("proxy stop must not run the clear Wi-Fi proxy flow when state is stopped")
            return DriverClient(host: "127.0.0.1", port: 1)
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        XCTAssertThrowsError(try ProxyService.stop(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("PROXY_NOT_RUNNING"))
        }
    }

    func testProxyStopRejectsStoppedStateBeforeComparingActiveDriver() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try writeDriverLock(udid: "DEVICE-B", paths: paths)
        let state = ProxySessionState(
            sessionId: "proxy-stopped",
            status: "stopped",
            startedAt: 1,
            stoppedAt: 2,
            udid: "DEVICE-A",
            flowFile: "capture.flow"
        )
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))

        XCTAssertThrowsError(try ProxyService.stop(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("PROXY_NOT_RUNNING"))
            XCTAssertFalse(String(describing: error).contains("running for DEVICE-A"))
        }
    }

    func testProxyStopServerOnlyDoesNotRequireDriverLockAndKeepsLastCapture() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let flowFile = "\(root)/artifacts/proxy-test.mitm"
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/artifacts", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: flowFile))
        var state = ProxySessionState(
            sessionId: "proxy-running",
            status: "running",
            startedAt: 1,
            udid: "",
            flowFile: flowFile,
            mitmdumpPid: nil,
            mitmdumpPort: IOSUseProtocol.proxyMitmdumpPort
        )
        state.serverStatus = "running"
        state.deviceProxyStatus = "unknown"
        state.lastCapture = ProxyLastCapture(
            flowFile: flowFile,
            udid: "",
            startedAt: 1,
            stoppedAt: nil,
            status: "running",
            mitmdumpPid: nil,
            network: nil
        )
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))

        let output = try ProxyService.stop(serverOnly: true, paths: paths)

        XCTAssertTrue(output.contains("Device Wi-Fi proxy was not changed"))
        let stopped = try XCTUnwrap(ProxyService.readState(paths: paths))
        XCTAssertEqual(stopped.status, "stopped")
        XCTAssertEqual(stopped.serverStatus, "stopped")
        XCTAssertEqual(stopped.lastCapture?.flowFile, flowFile)
    }

    func testProxyStopRejectsServerOnlyStateBeforeClearingActiveDeviceProxy() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let flowFile = "\(root)/artifacts/proxy-test.mitm"
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try writeDriverLock(udid: "DEVICE-A", paths: paths)
        var state = ProxySessionState(
            sessionId: "proxy-running",
            status: "running",
            startedAt: 1,
            udid: "",
            flowFile: flowFile,
            mitmdumpPid: nil,
            mitmdumpPort: IOSUseProtocol.proxyMitmdumpPort
        )
        state.serverStatus = "running"
        state.deviceProxyStatus = "unknown"
        state.lastCapture = ProxyLastCapture(
            flowFile: flowFile,
            udid: "",
            startedAt: 1,
            stoppedAt: nil,
            status: "running",
            mitmdumpPid: nil,
            network: nil
        )
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("default proxy stop must not clear Wi-Fi proxy for a server-only session")
            return DriverClient(host: "127.0.0.1", port: 1)
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        XCTAssertThrowsError(try ProxyService.stop(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("proxy stop --server"))
        }
    }

    func testProxyReadUsesLastCaptureWhenStoppedAndAppliesLastLines() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let flowFile = "\(root)/artifacts/proxy-test.mitm"
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/artifacts", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: flowFile))
        var state = ProxySessionState(
            sessionId: "proxy-stopped",
            status: "stopped",
            startedAt: 1,
            stoppedAt: 2,
            udid: "DEVICE-A",
            flowFile: flowFile
        )
        state.lastCapture = ProxyLastCapture(
            flowFile: flowFile,
            udid: "DEVICE-A",
            startedAt: 1,
            stoppedAt: 2,
            status: "stopped",
            mitmdumpPid: nil,
            network: nil
        )
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))
        ProxyService.mitmdumpReadOverrideForTesting = { file, raw, filter in
            XCTAssertEqual(file, flowFile)
            XCTAssertTrue(raw)
            XCTAssertEqual(filter, "~m POST")
            return "one\ntwo\nthree\n"
        }

        XCTAssertEqual(
            try ProxyService.read(filter: "~m POST", raw: true, last: 2, paths: paths),
            "two\nthree\n"
        )
    }

    func testProxyReadFailsWhenNoLastCaptureExists() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])

        XCTAssertThrowsError(try ProxyService.read(filter: nil, raw: false, last: nil, paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("ios-use proxy start"))
        }
    }

    func testProxyReadDoesNotInferCaptureFromSessionFlowFile() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let flowFile = "\(root)/artifacts/proxy-test.mitm"
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/artifacts", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: flowFile))
        let state = ProxySessionState(
            sessionId: "proxy-legacy",
            status: "stopped",
            startedAt: 1,
            stoppedAt: 2,
            udid: "DEVICE-A",
            flowFile: flowFile
        )
        try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))
        ProxyService.mitmdumpReadOverrideForTesting = { _, _, _ in
            XCTFail("proxy read must only use explicit lastCapture")
            return ""
        }

        XCTAssertThrowsError(try ProxyService.read(filter: nil, raw: false, last: nil, paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("ios-use proxy start"))
        }
    }

    func testMitmdumpProcessValidationRejectsUnrelatedPid() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }

        XCTAssertFalse(ProxyService.isMitmdumpProcessForTesting(pid: process.processIdentifier, expectedFlowFile: nil))
    }

    func testProxyCAPathUsesIsolatedIOSUseHome() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])

        XCTAssertEqual(ProxyService.caPathForTesting(paths: paths), "\(root)/mitmproxy/mitmproxy-ca-cert.pem")
    }

    func testProxyDoctorReportsCATrustRecordStatus() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/mitmproxy", withIntermediateDirectories: true)
        try "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n".write(
            toFile: "\(root)/mitmproxy/mitmproxy-ca-cert.pem",
            atomically: true,
            encoding: .utf8
        )

        let output = ProxyService.doctor(paths: paths)

        XCTAssertTrue(output.contains("CA generated"))
        XCTAssertTrue(output.contains("CA trust record: not recorded"))
    }

    func testProxyStartMitmdumpArgumentsDisableHTTP2() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let flowFile = "\(root)/artifacts/proxy-test.mitm"

        let arguments = ProxyService.mitmdumpStartArgumentsForTesting(flowFile: flowFile, paths: paths)

        XCTAssertEqual(arguments.first, "mitmdump")
        XCTAssertTrue(arguments.contains("--mode"))
        XCTAssertTrue(arguments.contains("regular"))
        XCTAssertTrue(arguments.contains("--listen-port"))
        XCTAssertTrue(arguments.contains(String(IOSUseProtocol.proxyMitmdumpPort)))
        XCTAssertTrue(arguments.contains("--set"))
        XCTAssertTrue(arguments.contains("confdir=\(root)/mitmproxy"))
        XCTAssertTrue(arguments.contains("ssl_insecure=true"))
        XCTAssertTrue(arguments.contains("http2=false"))
        XCTAssertTrue(arguments.contains("connection_strategy=eager"))
        XCTAssertTrue(arguments.contains("save_stream_file=\(flowFile)"))
    }

    func testProxyPortOwnersParseLsofOutput() throws {
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            XCTAssertEqual(executable, "lsof")
            XCTAssertEqual(arguments, ["-nP", "-iTCP:\(IOSUseProtocol.proxyMitmdumpPort)", "-sTCP:LISTEN", "-Fp"])
            return "p123\np456\np123\n"
        }

        XCTAssertEqual(ProxyService.listeningPortOwnersForTesting(port: IOSUseProtocol.proxyMitmdumpPort), [123, 456])
    }

    func testConfigCASkipsInstallFlowWhenTrustRecordMatches() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let pem = "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n"
        try FileManager.default.createDirectory(atPath: "\(root)/mitmproxy", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try pem.write(toFile: "\(root)/mitmproxy/mitmproxy-ca-cert.pem", atomically: true, encoding: .utf8)
        let fingerprint = ProxyService.fingerprintPEMForTesting(pem)
        let record: [String: Any] = [
            "DEVICE-1": ["fingerprint": fingerprint, "installedAt": 1]
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: URL(fileURLWithPath: "\(root)/state/proxy-ca.json"))

        try writeDriverLock(udid: "DEVICE-1", paths: paths)

        let output = try ProxyService.configCA(paths: paths)

        XCTAssertEqual(output, "CA already installed and trusted on device.\n")
    }

    func testConfigCAMarkTrustedWritesTrustRecordWithoutInstallFlow() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let pem = "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n"
        try FileManager.default.createDirectory(atPath: "\(root)/mitmproxy", withIntermediateDirectories: true)
        try pem.write(toFile: "\(root)/mitmproxy/mitmproxy-ca-cert.pem", atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "DEVICE-1", paths: paths)

        let output = try ProxyService.configCA(markTrusted: true, paths: paths)

        XCTAssertEqual(output, "CA trust marked as manually confirmed on device.\n")
        let secondOutput = try ProxyService.configCA(paths: paths)
        XCTAssertEqual(secondOutput, "CA already installed and trusted on device.\n")
        let state = try XCTUnwrap(ProxyService.readState(paths: paths))
        XCTAssertEqual(state.caInstalled, true)
        XCTAssertEqual(state.caStatus, "trusted")
    }

    func testConfigCAMarkTrustedRequiresExistingCA() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "DEVICE-1", paths: paths)

        XCTAssertThrowsError(try ProxyService.configCA(markTrusted: true, paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("No mitmproxy CA found"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/mitmproxy/mitmproxy-ca-cert.pem"))
    }

    private func temporaryRoot() throws -> String {
        let root = NSTemporaryDirectory() + "ios-use-swift-proxy-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        return root
    }

    private func writeDriverLock(udid: String, paths: IOSUsePaths) throws {
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: udid,
                deviceName: "Simulator",
                deviceVersion: "26.0",
                deviceType: "simulator",
                startedAt: 1
            ),
            paths: paths
        )
    }
}
