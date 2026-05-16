import XCTest
@testable import IOSUseCLI

final class DeviceServiceTests: XCTestCase {
    override func tearDown() {
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.resetCacheForTesting()
        super.tearDown()
    }

    func testParseDeviceOutputSeparatesRealDevicesAndSimulators() {
        let output = """
        == Devices ==
        My iPhone (18.7.1) (00008110-001234567890801E)
        == Simulators ==
        iPhone 16 (26.0.1) (F7B6FCE5-D07B-4A9B-B369-68F83C358778)
        """

        XCTAssertEqual(DeviceService.parseDeviceOutput(output), [
            IOSDevice(name: "My iPhone", version: "18.7.1", udid: "00008110-001234567890801E", kind: .real),
            IOSDevice(name: "iPhone 16", version: "26.0.1", udid: "F7B6FCE5-D07B-4A9B-B369-68F83C358778", kind: .simulator)
        ])
    }

    func testParseBootedSimulatorsCapturesRuntimeVersion() {
        let output = """
        == Devices ==
        -- iOS 26.0.1 --
            IOSUseTest (F7B6FCE5-D07B-4A9B-B369-68F83C358778) (Booted)
            Other (11111111-1111-1111-1111-111111111111) (Shutdown)
        """

        XCTAssertEqual(DeviceService.parseBootedSimulators(output), [
            IOSDevice(name: "IOSUseTest", version: "26.0.1", udid: "F7B6FCE5-D07B-4A9B-B369-68F83C358778", kind: .simulator)
        ])
    }

    func testFormatDeviceLabelIncludesConfiguredTag() {
        let device = IOSDevice(name: "IOSUseTest", version: "26.0.1", udid: "SIM-1", kind: .simulator)

        XCTAssertEqual(
            DeviceService.format(device, configured: ["SIM-1"]),
            "IOSUseTest | iOS 26.0.1 | Simulator | UDID: SIM-1 | configured"
        )
    }

    func testShellRunHandlesLargeStdoutWithoutPipeDeadlock() throws {
        let output = try Shell.run("/bin/sh", arguments: [
            "-c",
            "i=0; while [ $i -lt 10000 ]; do printf 'abcdefghijklmnopqrstuvwxyz0123456789\\n'; i=$((i + 1)); done"
        ])

        XCTAssertEqual(output.split(separator: "\n").count, 10000)
    }

    func testListDevicesOverrideBypassesCacheForIsolatedTests() throws {
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": "/tmp/ios-use-device-cache-\(UUID().uuidString)"])
        var calls = 0
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            calls += 1
            return [IOSDevice(name: "Phone \(calls)", version: "26.0", udid: "REAL-\(calls)", kind: .real)]
        }

        XCTAssertEqual(try DeviceService.listDevices(simulatorOnly: false, paths: paths).first?.udid, "REAL-1")
        XCTAssertEqual(try DeviceService.listDevices(simulatorOnly: false, paths: paths).first?.udid, "REAL-2")
        XCTAssertEqual(calls, 2)
    }
}
