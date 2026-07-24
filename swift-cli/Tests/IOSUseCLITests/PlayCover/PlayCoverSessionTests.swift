import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverSessionTests: XCTestCase {
    override func tearDown() {
        PlayCoverSessionService.launchOverrideForTesting = nil
        PlayCoverSessionService.terminateOverrideForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        super.tearDown()
    }

    func testStartWithoutAppUsesLastPreparedAndStopClearsSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let preparedApp = "\(root)/Prepared.app"
        try PlayCoverSessionService.recordPrepared(
            manifest(appPath: preparedApp),
            paths: paths
        )

        var launches: [(String, Double)] = []
        PlayCoverSessionService.launchOverrideForTesting = { appPath, timeout in
            launches.append((appPath, timeout))
            return self.launchResult(appPath: appPath)
        }

        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])
        let start = cli.run(arguments: ["start", "--playcover"])

        XCTAssertEqual(start.exitCode, 0)
        XCTAssertEqual(
            start.stdout,
            "PlayCover session started for com.example.demo (pid 4242)\n"
        )
        XCTAssertEqual(launches.map(\.0), [preparedApp])
        XCTAssertEqual(launches.map(\.1), [15])

        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.udid, "playcover:com.example.demo")
        XCTAssertEqual(lock.deviceType, "playcover")
        XCTAssertEqual(lock.deviceName, "iPhone16,2")
        XCTAssertEqual(lock.runnerPid, 4242)
        XCTAssertEqual(lock.bundleId, "com.example.demo")
        XCTAssertEqual(lock.playCoverAppPath, preparedApp)
        XCTAssertEqual(lock.profileHash, "profile-hash")

        var terminated: [String] = []
        PlayCoverSessionService.terminateOverrideForTesting = { appPath in
            terminated.append(appPath)
            return 4242
        }
        let stop = cli.run(arguments: ["stop"])

        XCTAssertEqual(stop.exitCode, 0)
        XCTAssertEqual(
            stop.stdout,
            "PlayCover App stopped (pid 4242)\nPlayCover session stopped\n"
        )
        XCTAssertEqual(terminated, [preparedApp])
        XCTAssertNil(try SessionService.readDriverLockInfo(paths: paths))
    }

    func testExplicitAppOverridesLastPreparedForActiveSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let rememberedApp = "\(root)/Remembered.app"
        let explicitApp = "\(root)/Explicit.app"
        try PlayCoverSessionService.recordPrepared(
            manifest(appPath: rememberedApp),
            paths: paths
        )

        PlayCoverSessionService.launchOverrideForTesting = { appPath, timeout in
            XCTAssertEqual(appPath, explicitApp)
            XCTAssertEqual(timeout, 0.8, accuracy: 0.001)
            return self.launchResult(appPath: appPath)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: [
                "start", "--playcover",
                "--app", explicitApp,
                "--timeout", "800ms",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            try SessionService.readDriverLockInfo(paths: paths)?.playCoverAppPath,
            explicitApp
        )
        XCTAssertEqual(
            try PlayCoverSessionService.readPreparedReference(paths: paths)?.appPath,
            rememberedApp
        )
    }

    func testStartRejectsExistingSessionBeforeLaunching() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "SIM-1",
                deviceName: "Simulator",
                deviceVersion: "26.0",
                deviceType: "simulator"
            ),
            paths: paths
        )
        PlayCoverSessionService.launchOverrideForTesting = { _, _ in
            XCTFail("an existing session must block PlayCover launch")
            return self.launchResult(appPath: "/unused.app")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["start", "--playcover", "--app", "/work/Demo.app"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Driver already started for SIM-1"))
    }

    func testStartCleansLaunchedAppWhenSessionLockCannotBeWritten() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try Data("not-a-directory".utf8).write(
            to: URL(fileURLWithPath: "\(root)/state")
        )
        PlayCoverSessionService.launchOverrideForTesting = { appPath, _ in
            self.launchResult(appPath: appPath)
        }
        var terminated: [String] = []
        PlayCoverSessionService.terminateOverrideForTesting = { appPath in
            terminated.append(appPath)
            return 4242
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: [
                "start", "--playcover",
                "--app", "\(root)/Prepared.app",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(terminated, ["\(root)/Prepared.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))
    }

    func testStopFailurePreservesPlayCoverSessionLock() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writePlayCoverLock(paths: paths)
        PlayCoverSessionService.terminateOverrideForTesting = { _ in
            throw PlayCoverBackendError.terminateFailed("fixture failure")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["stop"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("fixture failure"))
        XCTAssertNotNil(try SessionService.readDriverLockInfo(paths: paths))
    }

    func testDriverCommandRoutesToPlayCoverWithoutCreatingXCTestClient() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writePlayCoverLock(paths: paths)
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("PlayCover session must not create an XCTest driver client")
            fatalError("unexpected XCTest client")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["dom"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("PlayCover active session"))
        XCTAssertTrue(result.stderr.contains("IOSUsePlayRuntime automation transport"))
    }

    func testHostTargetCommandDoesNotFallBackToDeviceBackend() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writePlayCoverLock(paths: paths)

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["apps"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("does not support `apps` yet"))
    }

    func testIncompletePlayCoverLockIsRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "playcover:broken",
                deviceName: "iPhone16,2",
                deviceVersion: "Mac Catalyst",
                deviceType: "playcover"
            ),
            paths: paths
        )

        XCTAssertThrowsError(try SessionService.readDriverLockInfo(paths: paths)) {
            XCTAssertTrue(String(describing: $0).contains("incomplete PlayCover session"))
        }
    }

    private func writePlayCoverLock(paths: IOSUsePaths) throws {
        try SessionService.writeDriverLock(
            info: PlayCoverSessionService.makeSessionInfo(
                from: launchResult(appPath: "/work/Demo.app")
            ),
            paths: paths
        )
    }

    private func launchResult(appPath: String) -> PlayCoverSessionService.LaunchResult {
        PlayCoverSessionService.LaunchResult(
            appPath: appPath,
            bundleIdentifier: "com.example.demo",
            profileHash: "profile-hash",
            productType: "iPhone16,2",
            pid: 4242
        )
    }

    private func manifest(appPath: String) -> PlayCoverPrepareManifest {
        PlayCoverPrepareManifest(
            schemaVersion: 1,
            backend: "playcover-headless",
            sourceAppPath: "/fixtures/Demo.app",
            preparedAppPath: appPath,
            bundleIdentifier: "com.example.demo",
            executableName: "Demo",
            profileHash: "profile-hash",
            runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
            runtimeFrameworkName: "IOSUsePlayRuntime.framework",
            convertedMachOs: ["Demo"],
            preparedAt: "2026-07-25T00:00:00Z",
            helloPath: "/state/hello.json"
        )
    }

    private func temporaryRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-session-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root.path
    }
}
