import XCTest
@testable import IOSUseCLI

final class OSLogServiceTests: XCTestCase {
    override func tearDown() {
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

    func testOslogRejectsMissingUdidBeforeTouchingEnvironment() {
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": "/tmp/ios-use-swift-oslog"]).run(arguments: ["oslog", "--name", "logs"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("oslog requires --udid or an active session"))
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
}
