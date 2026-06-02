import XCTest
@testable import IOSUseCLI

final class OSLogServiceTests: XCTestCase {
    override func tearDown() {
        RealDeviceOSLogService.collectorForTesting = nil
        RealDeviceOSTraceService.collectorForTesting = nil
        OSLogService.resetSimulatorLogCollectorForTesting()
        super.tearDown()
    }

    func testOslogClearIsRejected() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": home]).run(arguments: ["oslog", "--clear"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains("unknown option '--clear'"))
    }

    func testOslogRejectsMissingTargetBeforeTouchingUsbDevices() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("oslog without --udid or driver.lock must not auto-select a USB device")
            return []
        }
        addTeardownBlock { DeviceService.listDevicesOverrideForTesting = nil }
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": home]).run(arguments: ["oslog"])

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

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["oslog", "--pattern", "ready", "--timeout", "0"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("ready"))
    }

    func testOslogExplicitUnbootedSimulatorDoesNotFallbackToRealSyslog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        let simulatorUdid = "00000000-0000-0000-0000-000000000001"
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
            return []
        }
        RealDeviceOSTraceService.collectorForTesting = { _, _, _ in
            XCTFail("explicit Simulator UDID must not fall back to real-device os_trace")
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

    func testSimulatorFetchPrintsFilteredLinesAndRegexFlags() throws {
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
            source: OSLogOptions.SourceFilter(process: "Demo"),
            timeout: 1,
            paths: paths
        )

        XCTAssertTrue(output.contains("Alpha READY"))
        XCTAssertFalse(output.contains("beta idle"))
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
            source: OSLogOptions.SourceFilter(),
            timeout: 1,
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
            source: OSLogOptions.SourceFilter(),
            timeout: 1,
            paths: paths,
            deviceTypeHint: "simulator"
        )

        XCTAssertTrue(output.contains("hinted"))
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
            source: OSLogOptions.SourceFilter(),
            timeout: 1,
            paths: paths
        )

        XCTAssertGreaterThanOrEqual(calls, 2)
        XCTAssertTrue(output.contains("ready"))
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
            source: OSLogOptions.SourceFilter(),
            timeout: 1,
            paths: paths
        )

        XCTAssertEqual(calls, 1)
    }

    func testSimulatorPollingDedupesWithinSingleCommandOnly() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-oslog-\(UUID().uuidString)").path
        ])
        var calls = 0
        OSLogService.simulatorLogCollector = { _, _, _ in
            calls += 1
            return [
                "May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: booting",
                "May 16 10:00:01 iPhone Demo(Demo)[1] <Notice>: ready",
                "May 16 10:00:01 iPhone Demo(Demo)[1] <Notice>: ready",
            ]
        }

        let first = try OSLogService.fetchSimulator(
            udid: "SIM-DEDUPE",
            pattern: "ready",
            flags: nil,
            source: OSLogOptions.SourceFilter(),
            timeout: 1,
            paths: paths
        )
        let second = try OSLogService.fetchSimulator(
            udid: "SIM-DEDUPE",
            pattern: "ready",
            flags: nil,
            source: OSLogOptions.SourceFilter(),
            timeout: 1,
            paths: paths
        )

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(first.split(separator: "\n").filter { $0.contains("ready") }.count, 1)
        XCTAssertEqual(second.split(separator: "\n").filter { $0.contains("ready") }.count, 1)
    }

    func testOSTracePacketParserFormatsProcessPidAndMessage() throws {
        let processPath = Data("/path/IOSUseDriverRunner\0".utf8)
        let imagePath = Data("/usr/lib/libswift.dylib\0".utf8)
        let message = Data("[driver] ready\0".utf8)
        var packet = Data(repeating: 0, count: 129)
        packet[0] = 2
        putUInt32LE(8, into: &packet, at: 1)
        putUInt32LE(129, into: &packet, at: 5)
        putUInt32LE(42, into: &packet, at: 9)
        putUInt64LE(42, into: &packet, at: 13)
        putUInt16LE(UInt16(processPath.count), into: &packet, at: 37)
        putUInt64LE(1_717_000_000, into: &packet, at: 55)
        putUInt32LE(123, into: &packet, at: 63)
        packet[68] = 0x01
        putUInt16LE(UInt16(imagePath.count), into: &packet, at: 107)
        putUInt32LE(UInt32(message.count), into: &packet, at: 109)
        packet.append(processPath)
        packet.append(imagePath)
        packet.append(message)

        let event = try XCTUnwrap(RealDeviceOSTraceService.parseEventPacket(packet))

        XCTAssertEqual(event.processName, "IOSUseDriverRunner")
        XCTAssertEqual(event.pid, 42)
        XCTAssertEqual(event.message, "[driver] ready")
        XCTAssertTrue(event.rawLine.contains("IOSUseDriverRunner[42] <Info>: [driver] ready"))
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
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
        data[offset + 4] = UInt8((value >> 32) & 0xff)
        data[offset + 5] = UInt8((value >> 40) & 0xff)
        data[offset + 6] = UInt8((value >> 48) & 0xff)
        data[offset + 7] = UInt8((value >> 56) & 0xff)
    }
}
