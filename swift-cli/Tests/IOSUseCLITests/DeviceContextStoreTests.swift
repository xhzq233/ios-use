import XCTest
@testable import IOSUseCLI

final class DeviceContextStoreTests: XCTestCase {
    func testTwoRunningContextsRequireExplicitSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": root.path,
        ])
        let first = try paths.deviceContext(
            DeviceContextStore.realDeviceID("DEVICE-1")
        )
        let second = try paths.deviceContext(
            DeviceContextStore.realDeviceID("DEVICE-2")
        )
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "DEVICE-1",
                deviceName: "First",
                deviceVersion: "1",
                deviceType: "real"
            ),
            paths: first
        )
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "DEVICE-2",
                deviceName: "Second",
                deviceVersion: "1",
                deviceType: "real"
            ),
            paths: second
        )

        XCTAssertEqual(DeviceContextStore.sessions(paths: paths).count, 2)
        XCTAssertThrowsError(
            try DeviceContextStore.activeContext(
                explicitDeviceID: nil,
                paths: paths
            )
        )
        XCTAssertEqual(
            try DeviceContextStore.activeContext(
                explicitDeviceID: "real:DEVICE-2",
                paths: paths
            ).info.udid,
            "DEVICE-2"
        )
    }
}
