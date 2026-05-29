import XCTest
@testable import IOSUseCLI

final class OSLogServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = OSLogService.clear()
    }

    override func tearDown() {
        RealDeviceOSLogService.collectorForTesting = nil
        OSLogService.resetSimulatorLogCollectorForTesting()
        _ = OSLogService.clear()
        super.tearDown()
    }

    func testClearKeepsUserVisibleContract() {
        XCTAssertEqual(OSLogService.clear(), "  → oslog: cleared=0\n")
    }

    func testOslogClearDoesNotRequireDriverSession() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": home]).run(arguments: ["oslog", "--clear"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "  → oslog: cleared=0\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testOslogRejectsMissingTargetBeforeTouchingUsbDevices() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("oslog without --udid or driver.lock must not auto-select a USB device")
            return []
        }
        addTeardownBlock { DeviceService.listDevicesOverrideForTesting = nil }
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": home]).run(arguments: ["oslog", "--name", "logs"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("oslog requires --udid or an active driver"))
    }

    func testOslogUsesActiveDriverLockWhenUdidIsOmitted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "SIM-LOCK",
                deviceName: "iPhone",
                deviceVersion: "26.0",
                deviceType: "simulator",
                startedAt: 1
            ),
            paths: paths
        )
        OSLogService.simulatorLogCollector = { udid, _, _ in
            XCTAssertEqual(udid, "SIM-LOCK")
            return ["May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: ready"]
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["oslog", "--pattern", "ready", "--timeout", "0", "--name", "active-lock"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("matched=1"))
        XCTAssertTrue(result.stdout.contains("active-lock.log"))
    }

    func testOslogExplicitUnbootedSimulatorDoesNotFallbackToRealSyslog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        let simulatorUdid = "00000000-0000-0000-0000-000000000001"
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
            return []
        }
        RealDeviceOSLogService.collectorForTesting = { _, _ in
            XCTFail("explicit Simulator UDID must not fall back to real-device syslog")
            return []
        }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["oslog", "--udid", simulatorUdid, "--timeout", "0"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Simulator \(simulatorUdid) is not booted or not found"))
    }

    func testSimulatorFetchUsesTimestampDefaultNameAndRegexFlags() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        ])
        OSLogService.simulatorLogCollector = { _, _, _ in
            [
                "May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: Alpha READY",
                "May 16 10:00:01 iPhone Demo(Demo)[1] <Notice>: beta idle",
            ]
        }

        let output = try OSLogService.fetchSimulator(
            udid: "SIM-1",
            pattern: "ready",
            flags: "ig",
            bundleId: "com.example.Demo",
            timeout: 1,
            name: nil,
            paths: paths
        )

        XCTAssertTrue(output.contains("matched=1 total=2"))
        XCTAssertTrue(output.contains("/artifacts/oslog-"))
        let path = output.split(separator: "→").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = try XCTUnwrap(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved))
        let content = try String(contentsOfFile: saved)
        XCTAssertTrue(content.contains("Alpha READY"))
        XCTAssertFalse(content.contains("beta idle"))
    }

    func testSimulatorFetchRejectsInvalidRegexFlags() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        ])
        OSLogService.simulatorLogCollector = { _, _, _ in ["May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: ready"] }

        XCTAssertThrowsError(try OSLogService.fetchSimulator(
            udid: "SIM-1",
            pattern: "ready",
            flags: "z",
            bundleId: nil,
            timeout: 1,
            name: "invalid",
            paths: paths
        )) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid regex flag"))
        }
    }

    func testFetchUsesSimulatorDeviceTypeHintWithoutDiscovery() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        ])
        OSLogService.simulatorLogCollector = { udid, _, _ in
            XCTAssertEqual(udid, "SIM-HINT")
            return ["May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: hinted"]
        }

        let output = try OSLogService.fetch(
            udid: "SIM-HINT",
            pattern: "hinted",
            flags: nil,
            bundleId: nil,
            timeout: 1,
            name: "hinted",
            paths: paths,
            deviceTypeHint: "simulator"
        )

        XCTAssertTrue(output.contains("matched=1 total=1"))
    }

    func testSimulatorFetchPollsUntilTimeoutForPattern() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        ])
        var calls = 0
        OSLogService.simulatorLogCollector = { _, _, _ in
            calls += 1
            if calls == 1 {
                return ["May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: booting"]
            }
            return ["May 16 10:00:01 iPhone Demo(Demo)[1] <Notice>: ready"]
        }

        let output = try OSLogService.fetchSimulator(
            udid: "SIM-POLL",
            pattern: "ready",
            flags: nil,
            bundleId: nil,
            timeout: 1,
            name: "poll",
            paths: paths
        )

        XCTAssertGreaterThanOrEqual(calls, 2)
        XCTAssertTrue(output.contains("matched=1 total=2"))
    }

    func testSimulatorFetchWithoutPatternDoesNotPoll() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        ])
        var calls = 0
        OSLogService.simulatorLogCollector = { _, _, _ in
            calls += 1
            return ["May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: line"]
        }

        _ = try OSLogService.fetchSimulator(
            udid: "SIM-NO-POLL",
            pattern: nil,
            flags: nil,
            bundleId: nil,
            timeout: 1,
            name: "single",
            paths: paths
        )

        XCTAssertEqual(calls, 1)
    }

    func testClearWithUdidOnlyClearsMatchingDeviceBuffer() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        ])
        var linesByUdid: [String: [String]] = [
            "SIM-1": ["May 16 10:00:00 iPhone One(One)[1] <Notice>: one"],
            "SIM-2": ["May 16 10:00:00 iPhone Two(Two)[2] <Notice>: two"],
        ]
        OSLogService.simulatorLogCollector = { udid, _, _ in
            let lines = linesByUdid[udid] ?? []
            linesByUdid[udid] = []
            return lines
        }

        _ = try OSLogService.fetchSimulator(udid: "SIM-1", pattern: nil, flags: nil, bundleId: nil, timeout: 1, name: "one", paths: paths)
        _ = try OSLogService.fetchSimulator(udid: "SIM-2", pattern: nil, flags: nil, bundleId: nil, timeout: 1, name: "two", paths: paths)

        XCTAssertEqual(OSLogService.clear(udid: "SIM-1"), "  → oslog: cleared=1\n")
        let output = try OSLogService.fetchSimulator(udid: "SIM-2", pattern: nil, flags: nil, bundleId: nil, timeout: 1, name: "two-again", paths: paths)
        XCTAssertTrue(output.contains("matched=1 total=1"))
    }

    func testCLIClearWithUdidOnlyClearsThatDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        OSLogService.simulatorLogCollector = { udid, _, _ in
            ["May 16 10:00:00 iPhone \(udid)(Demo)[1] <Notice>: \(udid)"]
        }

        _ = try OSLogService.fetchSimulator(udid: "SIM-1", pattern: nil, flags: nil, bundleId: nil, timeout: 1, name: "one", paths: paths)
        _ = try OSLogService.fetchSimulator(udid: "SIM-2", pattern: nil, flags: nil, bundleId: nil, timeout: 1, name: "two", paths: paths)

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["oslog", "--clear", "--udid", "SIM-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "  → oslog: cleared=1\n")
        let output = try OSLogService.fetchSimulator(udid: "SIM-2", pattern: nil, flags: nil, bundleId: nil, timeout: 1, name: "two-again", paths: paths)
        XCTAssertTrue(output.contains("total=1"))
    }

    func testOutputNameCannotEscapeArtifactsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        OSLogService.simulatorLogCollector = { _, _, _ in ["May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: ready"] }

        let output = try OSLogService.fetchSimulator(
            udid: "SIM-1",
            pattern: nil,
            flags: nil,
            bundleId: nil,
            timeout: 1,
            name: "../outside",
            paths: paths
        )

        XCTAssertTrue(output.contains("\(paths.artifacts)/outside.log"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(paths.artifacts)/outside.log"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/outside.log"))
    }
}
