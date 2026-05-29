import XCTest
@testable import IOSUseCLI

final class DeviceServiceTests: XCTestCase {
    override func tearDown() {
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.usbDeviceUdidsOverrideForTesting = nil
        DeviceService.realDeviceResolverForTesting = nil
        DeviceService.resetCacheForTesting()
        Shell.runOverrideForTesting = nil
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

    func testFormatDeviceLabelIncludesDriverUpdateHint() {
        let device = IOSDevice(name: "Phone", version: "26.2", udid: "REAL-1", kind: .real)

        XCTAssertEqual(
            DeviceService.format(device, configuredDevices: ["REAL-1": DeviceService.ConfiguredDevice(driverVersion: "0.9.0")]),
            "Phone | iOS 26.2 | Device | UDID: REAL-1 | configured | driver update required: run ios-use config --udid REAL-1"
        )
    }

    func testUsbOnlyDevicesFiltersAndPreservesUsbmuxOrder() throws {
        DeviceService.usbDeviceUdidsOverrideForTesting = {
            ["00008150-0015309E2EE3401C", "CE83141B-D0FB-5983-B0DB-4C301BB773F6"]
        }
        let devices = [
            IOSDevice(name: "WiFiOnly", version: "26.0", udid: "FFFFFFFF-FFFFFFFFFFFFFFFF", kind: .real),
            IOSDevice(name: "SecondUSB", version: "26.2", udid: "00008150-0015309E2EE3401C", kind: .real),
            IOSDevice(name: "FirstUSB", version: "26.1", udid: "CE83141B-D0FB-5983-B0DB-4C301BB773F6", kind: .real),
        ]

        let usbOnly = try DeviceService.usbOnlyDevices(from: devices)

        XCTAssertEqual(usbOnly.map(\.name), ["SecondUSB", "FirstUSB"])
    }

    func testListRealDevicesReturnsBeforeXctraceWhenNoUsbDevices() throws {
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": "/tmp/ios-use-device-no-usb-\(UUID().uuidString)"])
        DeviceService.usbDeviceUdidsOverrideForTesting = { [] }

        XCTAssertEqual(try DeviceService.listDevices(simulatorOnly: false, paths: paths), [])
    }

    func testListRealDevicesUsesLockdownResolverWithoutXctrace() throws {
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": "/tmp/ios-use-device-lockdown-\(UUID().uuidString)"])
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-1"] }
        DeviceService.realDeviceResolverForTesting = { udid in
            IOSDevice(
                name: "Test Phone",
                version: "26.2",
                udid: udid,
                kind: .real,
                metadata: IOSDeviceMetadata(productType: "iPhone18,3", productName: "iPhone", buildVersion: "23C55", batteryCurrentCapacity: 99, status: "paired")
            )
        }
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun", arguments.first == "xctrace" {
                XCTFail("real devices path must not call xctrace")
            }
            return ""
        }

        let devices = try DeviceService.listDevices(simulatorOnly: false, paths: paths)

        XCTAssertEqual(devices.map(\.udid), ["REAL-1"])
        XCTAssertEqual(devices.first?.name, "Test Phone")
        XCTAssertEqual(
            DeviceService.format(devices[0], configuredDevices: [:], verbose: true),
            "Test Phone | iOS 26.2 | Device | UDID: REAL-1\n    product: iPhone | type: iPhone18,3 | build: 23C55 | battery: 99%"
        )
    }

    func testListRealDevicesKeepsUnpairedDeviceVisible() throws {
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": "/tmp/ios-use-device-unpaired-\(UUID().uuidString)"])
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-UNPAIRED"] }
        DeviceService.realDeviceResolverForTesting = { udid in
            IOSDevice(
                name: "Unknown",
                version: "",
                udid: udid,
                kind: .real,
                metadata: IOSDeviceMetadata(status: "pair required", detail: "No pair record found")
            )
        }

        let devices = try DeviceService.listDevices(simulatorOnly: false, paths: paths)

        XCTAssertEqual(devices.map(\.udid), ["REAL-UNPAIRED"])
        XCTAssertEqual(
            DeviceService.format(devices[0], configuredDevices: [:]),
            "Unknown | iOS unknown | Device | UDID: REAL-UNPAIRED | pair required"
        )
    }

    func testShellRunHandlesLargeStdoutWithoutPipeDeadlock() throws {
        let output = try Shell.run("/bin/sh", arguments: [
            "-c",
            "i=0; while [ $i -lt 10000 ]; do printf 'abcdefghijklmnopqrstuvwxyz0123456789\\n'; i=$((i + 1)); done"
        ])

        XCTAssertEqual(output.split(separator: "\n").count, 10000)
    }

    func testShellRunCombinedIncludesStderrOnSuccess() throws {
        let output = try Shell.runCombined("/bin/sh", arguments: [
            "-c",
            "printf out; printf err >&2"
        ])

        XCTAssertEqual(output, "outerr")
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
