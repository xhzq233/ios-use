import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class RemoteDriverConnectionTests: XCTestCase {
    private func withPaths(_ body: (IOSUsePaths) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #if os(Linux)
        try body(IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path]))
        #else
        try body(resolvePlayCoverTestPaths(environment: ["IOS_USE_HOME": root.path]))
        #endif
    }

    private func saveRemote(port: Int, id: String, paths: IOSUsePaths) throws -> IOSUsePaths {
        let connection = RemoteDeviceConnection(
            udid: id, driverBundleID: "com.example.driver.xctrunner",
            usbmux: .init(host: "127.0.0.1", port: 27015),
            driver: .init(host: "localhost", port: port)
        )
        let scoped = try paths.deviceContext(id)
        try DriverSessionStore.write(info: SessionService.Info(
            udid: id, deviceName: "Remote iPhone", deviceVersion: "", deviceType: "real",
            driverHost: connection.driver.host, driverPort: port, remoteConnection: connection,
            startMode: "remote"
        ), paths: scoped)
        return scoped
    }

    func testRemoteSessionsRouteDirectlyToTheirDriverEndpoints() throws {
        try withPaths { paths in
            let first = try FakeDriverServer(responseCount: 1)
            let second = try FakeDriverServer(responseCount: 1)
            defer { first.stop(); second.stop() }
            for (id, server) in [("remote-a", first), ("remote-b", second)] {
                _ = try saveRemote(port: Int(server.port), id: id, paths: paths)
            }
            XCTAssertThrowsError(try DeviceContextStore.activeContext(explicitDeviceID: nil, paths: paths))
            for (id, server) in [("remote-a", first), ("remote-b", second)] {
                let context = try DeviceContextStore.activeContext(explicitDeviceID: id, paths: paths)
                XCTAssertNotNil(context.info.remoteConnection)
                let client = LockedDriverClientSession(paths: context.paths)
                defer { client.close() }
                _ = try client.run { try $0.dom(raw: false, fresh: true, waitQuiescence: false) }
                XCTAssertEqual(server.acceptCount, 1)
            }
        }
    }

    func testOfflineRemoteDoesNotFallBackToLocalRuntime() throws {
        try withPaths { paths in
            let server = try FakeDriverServer(responseCount: 1)
            let scoped = try saveRemote(port: Int(server.port), id: "offline", paths: paths)
            server.stop()
            var launches = 0
            var terminations = 0
            SessionService.simulatorDriverLauncherForTesting = { _ in launches += 1 }
            SessionService.realDriverTerminatorForTesting = { _ in terminations += 1; return true }
            SessionService.simulatorDriverTerminatorForTesting = { _ in terminations += 1; return true }
            defer {
                SessionService.simulatorDriverLauncherForTesting = nil
                SessionService.realDriverTerminatorForTesting = nil
                SessionService.simulatorDriverTerminatorForTesting = nil
            }
            let original = try DriverSessionStore.readInfo(paths: scoped)
            let client = LockedDriverClientSession(paths: scoped)
            defer { client.close() }
            XCTAssertThrowsError(try client.run { try $0.dom(raw: false, fresh: false, waitQuiescence: false) })
            XCTAssertEqual(try DriverSessionStore.readInfo(paths: scoped), original)
            XCTAssertEqual(launches, 0)
            XCTAssertEqual(terminations, 0)
        }
    }

    func testConnectionValidatesBothEndpoints() throws {
        let valid = RemoteDeviceConnection.Endpoint(host: "localhost", port: 8102)
        for endpoint in [RemoteDeviceConnection.Endpoint(host: "http://localhost", port: 8102),
                         .init(host: "", port: 8102), .init(host: "bad host", port: 8102),
                         .init(host: "localhost", port: 0), .init(host: "localhost", port: 65536)] {
            for (usbmux, driver) in [(endpoint, valid), (valid, endpoint)] {
                let connection = RemoteDeviceConnection(
                    udid: "remote", driverBundleID: "com.example.driver.xctrunner", usbmux: usbmux, driver: driver
                )
                XCTAssertThrowsError(try connection.validate())
            }
        }
    }
}
