import XCTest
import Darwin
import IOSUseProtocol
@testable import IOSUseCLI

final class ProxyServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ConfigService.expectedDriverIdentityOverrideForTesting = { nil }
    }

    override func tearDown() {
        ConfigService.expectedDriverIdentityOverrideForTesting = nil
        ProxyService.mitmdumpReadOverrideForTesting = nil
        super.tearDown()
    }

    func testResolveUdidPrefersExplicitThenActiveSessionThenProxyState() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try SessionService.writeSimulatorSession(
            udid: "ACTIVE-DEVICE",
            deviceName: "Active",
            deviceVersion: "26.0",
            paths: paths
        )
        let stale = ProxySessionState(
            sessionId: "proxy-old",
            status: "stopped",
            startedAt: 1,
            udid: "STALE-PROXY-DEVICE",
            flowFile: "old.flow"
        )
        let data = try JSONEncoder().encode(stale)
        try data.write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))

        XCTAssertEqual(try ProxyService.resolveUdidForTesting("EXPLICIT", paths: paths), "EXPLICIT")
        XCTAssertEqual(try ProxyService.resolveUdidForTesting(nil, paths: paths), "ACTIVE-DEVICE")
    }

    func testProxyStartDefaultDoesNotUseActiveSessionOrStaleProxyState() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try SessionService.writeSimulatorSession(
            udid: "ACTIVE-SIM",
            deviceName: "Simulator",
            deviceVersion: "26.0",
            paths: paths
        )
        try JSONEncoder().encode(ProxySessionState(
            sessionId: "proxy-old",
            status: "stopped",
            startedAt: 1,
            udid: "STALE-PROXY-DEVICE",
            flowFile: "old.flow"
        )).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [] : [IOSDevice(name: "USB", version: "26.0", udid: "USB-DEVICE", kind: .real)]
        }
        SessionService.simulatorDriverReachableForTesting = { true }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.simulatorDriverReachableForTesting = nil
            SessionService.simulatorDriverLauncherForTesting = nil
            SessionService.realDriverReachableForTesting = nil
            SessionService.realDriverLauncherForTesting = nil
        }
        SessionService.realDriverReachableForTesting = { _ in true }
        SessionService.realDriverLauncherForTesting = { _, _ in }
        try """
        {"devices":{"USB-DEVICE":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)

        XCTAssertEqual(try ProxyService.resolveStartUdidForTesting(nil, paths: paths), "USB-DEVICE")
    }

    func testProxyStopRejectsMismatchedRequestedUdid() throws {
        let state = ProxySessionState(
            sessionId: "proxy-running",
            status: "running",
            startedAt: 1,
            udid: "DEVICE-A",
            flowFile: "capture.flow"
        )

        XCTAssertThrowsError(try ProxyService.resolveStopUdidForTesting("DEVICE-B", state: state)) { error in
            XCTAssertTrue(String(describing: error).contains("running for DEVICE-A"))
        }
        XCTAssertEqual(try ProxyService.resolveStopUdidForTesting(nil, state: state), "DEVICE-A")
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

        let output = try ProxyService.configCA(udid: "DEVICE-1", paths: paths)

        XCTAssertEqual(output, "CA already installed and trusted on device.\n")
    }

    func testProbeServerIdleSocketDoesNotBlockValidProbe() throws {
        let server = try ProxyProbeServer(token: "TOKEN")
        defer { server.stop() }
        let idle = try connectLocalhost(port: server.port)
        defer { Darwin.close(idle) }

        let valid = try connectLocalhost(port: server.port)
        defer { Darwin.close(valid) }
        let request = "GET /ios-use-probe?token=TOKEN HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        _ = request.withCString { ptr in
            Darwin.write(valid, ptr, strlen(ptr))
        }

        XCTAssertTrue(server.wait(timeoutMilliseconds: 2_000))
    }

    private func temporaryRoot() throws -> String {
        let root = NSTemporaryDirectory() + "ios-use-swift-proxy-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        return root
    }

    private func connectLocalhost(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("connect failed: \(errno)")
        }
        return fd
    }
}
