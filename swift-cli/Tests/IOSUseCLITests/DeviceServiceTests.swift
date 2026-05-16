import XCTest
import IOSUseCLI

final class DeviceServiceTests: XCTestCase {
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
}
