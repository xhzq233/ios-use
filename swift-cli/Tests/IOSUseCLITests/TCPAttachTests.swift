import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class TCPAttachTests: XCTestCase {
    private func withPaths(_ body: (IOSUsePaths) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #if os(Linux)
        try body(IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path]))
        #else
        try body(resolvePlayCoverTestPaths(environment: ["IOS_USE_HOME": root.path]))
        #endif
    }

    func testAttachRoutesTwoEndpointsAndDetachLeavesDriverAlive() throws {
        try withPaths { paths in
            let first = try FakeDriverServer(responseCount: 3)
            let second = try FakeDriverServer(responseCount: 2)
            defer { first.stop(); second.stop() }
            let cli = IOSUseCLI(pathsForTesting: paths)
            for (id, server) in [("remote-a", first), ("remote-b", second)] {
                let result = cli.run(arguments: ["attach", "--device", id,
                    "--host", "localhost", "--port", String(server.port), "--json"])
                XCTAssertEqual(result.exitCode, 0, result.stderr + result.stdout)
            }
            XCTAssertThrowsError(try DeviceContextStore.activeContext(explicitDeviceID: nil, paths: paths))
            for (id, server) in [("remote-a", first), ("remote-b", second)] {
                let context = try DeviceContextStore.activeContext(explicitDeviceID: id, paths: paths)
                XCTAssertTrue(context.info.isAttached)
                XCTAssertEqual(context.info.driverPort, server.port)
                let client = LockedDriverClientSession(paths: context.paths)
                defer { client.close() }
                _ = try client.run { try $0.dom(raw: false, fresh: true, waitQuiescence: false) }
                XCTAssertEqual(server.acceptCount, 2)
            }
            let firstPaths = try paths.deviceContext("remote-a")
            XCTAssertEqual(cli.run(arguments: ["detach", "--device", "remote-a"]).exitCode, 0)
            XCTAssertNil(try DriverSessionStore.readInfo(paths: firstPaths))
            XCTAssertEqual(DeviceContextStore.sessions(paths: paths).count, 1)
            let independentClient = DriverClient(port: UInt16(first.port))
            defer { independentClient.close() }
            _ = try independentClient.dom(raw: false, fresh: false)
            XCTAssertEqual(first.acceptCount, 3)
        }
    }

    func testRejectedProtocolDoesNotPersistAttachment() throws {
        try withPaths { paths in
            let server = try FakeDriverServer(responses: [ForyResponseFrame(ok: false, payload: Data())])
            defer { server.stop() }
            let cli = IOSUseCLI(pathsForTesting: paths)
            let result = cli.run(arguments: ["attach", "--device", "rejected", "--host", "127.0.0.1",
                "--port", String(server.port)])
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(DeviceContextStore.sessions(paths: paths).isEmpty)
        }
    }

    func testOfflineAttachmentDoesNotStartLocalRuntimeAndStopOnlyDetaches() throws {
        try withPaths { paths in
            let server = try FakeDriverServer(responseCount: 1)
            let scoped = try paths.deviceContext("offline")
            _ = try TCPAttachService.attach(options: .init(host: "127.0.0.1", port: server.port), paths: scoped)
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
            _ = try SessionService.stop(paths: scoped)
            XCTAssertNil(try DriverSessionStore.readInfo(paths: scoped))
            XCTAssertEqual(launches, 0)
            XCTAssertEqual(terminations, 0)
        }
    }

    func testLocalSessionCannotBeDetachedAndInvalidInputsCreateNoSession() throws {
        try withPaths { paths in
            let cli = IOSUseCLI(pathsForTesting: paths)
            for arguments in [
                ["attach", "--host", "localhost", "--port", "8102"],
                ["attach", "--device", "mac", "--host", "localhost", "--port", "8102"],
                ["attach", "--device", "remote", "--host", "localhost", "--port", "65536"],
                ["attach", "--device", "remote", "--host", "http://localhost", "--port", "8102"],
            ] {
                XCTAssertNotEqual(cli.run(arguments: arguments).exitCode, 0)
            }
            XCTAssertTrue(DeviceContextStore.sessions(paths: paths).isEmpty)
            let scoped = try paths.deviceContext("local")
            let info = SessionService.Info(udid: "local", deviceName: "test", deviceVersion: "", deviceType: "simulator")
            try DriverSessionStore.write(info: info, paths: scoped)
            XCTAssertThrowsError(try TCPAttachService.detach(paths: scoped))
            XCTAssertEqual(try DriverSessionStore.readInfo(paths: scoped), info)
        }
    }
}
