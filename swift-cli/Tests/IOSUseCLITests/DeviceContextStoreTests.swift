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
                explicitDeviceID: "DEVICE-2",
                paths: paths
            ).info.udid,
            "DEVICE-2"
        )
    }

    func testReplClientsAreIsolatedWithinOneHome() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).path,
        ])
        let pool = ReplDriverSessionPool()
        defer { pool.close() }
        let first = try paths.deviceContext("DEVICE-A")
        let second = try paths.deviceContext("DEVICE-B")
        XCTAssertTrue(pool.session(paths: first) === pool.session(paths: first))
        XCTAssertFalse(pool.session(paths: first) === pool.session(paths: second))
    }

}
