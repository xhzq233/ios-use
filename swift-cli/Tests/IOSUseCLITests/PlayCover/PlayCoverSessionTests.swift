import Darwin
import Foundation
import IOSUsePlayDevice
import XCTest
@testable import IOSUseCLI

final class PlayCoverSessionTests: XCTestCase {
    override func tearDown() {
        PlayCoverSessionService.launchOverrideForTesting = nil
        PlayCoverSessionService.terminateOverrideForTesting = nil
        PlayCoverSessionService
            .processExecutablePathOverrideForTesting = nil
        PlayCoverSessionService.signalOverrideForTesting = nil
        PlayCoverSessionService.processStateOverrideForTesting = nil
        PlayCoverSessionService
            .processStartTimeOverrideForTesting = nil
        PlayCoverSessionService
            .terminationIdentityProbeOverrideForTesting = nil
        PlayCoverSessionService.fastVerifyOverrideForTesting = nil
        PlayCoverService.launchAliasRootOverrideForTesting = nil
        PlayCoverManagedAppService.inspectOverrideForTesting = nil
        PlayCoverManagedAppService.verifyOverrideForTesting = nil
        PlayCoverManagedAppService.readManifestOverrideForTesting = nil
        PlayCoverManagedAppService.prepareOverrideForTesting = nil
        PlayCoverManagedAppService.runtimePathOverrideForTesting = nil
        PlayCoverManagedAppService.executablePathOverrideForTesting = nil
        PlayCoverManagedAppService
            .generationKeyOverrideForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        IOSUseCLI.playCoverDriverClientFactoryForTesting = nil
        StatusService.playCoverDiagnosticsForTesting = nil
        DeviceService.listDevicesOverrideForTesting = nil
        super.tearDown()
    }

    func testBareStartUsesFastVerifiedReferenceAndStopClearsLock()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        var fastVerificationPaths: [String] = []
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            fastVerificationPaths.append($0)
            return manifest
        }
        var launchInputs: [(
            app: String,
            sessionID: String,
            socket: String,
            timeout: Double
        )] = []
        PlayCoverSessionService.launchOverrideForTesting = {
            app,
            sessionID,
            socket,
            _,
            timeout in
            launchInputs.append(
                (app, sessionID, socket, timeout)
            )
            return self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socket,
                reused: true
            )
        }
        var terminatedSession: SessionService.Info?
        PlayCoverSessionService.terminateOverrideForTesting = {
            terminatedSession = $0
            return Int32($0.runnerPid ?? 0)
        }

        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        )
        let start = cli.run(
            arguments: ["start", "--playcover"]
        )

        XCTAssertEqual(start.exitCode, 0, start.stderr)
        XCTAssertTrue(start.stdout.contains("generation reused:"))
        XCTAssertTrue(start.stdout.contains(manifest.generationKey))
        XCTAssertTrue(start.stdout.contains("IOS_USE_HOME: \(fixture.root)"))
        XCTAssertTrue(
            start.stdout.contains(
                "PlayCover timing: inspect="
            )
        )
        for phase in [
            "clone=skipped",
            "convert=skipped",
            "sign=skipped",
            "verify=",
            "launch=",
            "alias=skipped",
            "openDispatch=skipped",
            "exactOwnership=skipped",
            "runtimeTransportPing=skipped",
            "readyGeometry=skipped",
            "total=",
        ] {
            XCTAssertTrue(start.stdout.contains(phase), phase)
        }
        XCTAssertEqual(
            fastVerificationPaths,
            [manifest.preparedAppPath]
        )
        XCTAssertEqual(launchInputs.count, 1)
        XCTAssertEqual(
            launchInputs.first?.app,
            manifest.preparedAppPath
        )
        XCTAssertEqual(launchInputs.first?.timeout, 15)
        let sessionID = try XCTUnwrap(
            launchInputs.first?.sessionID
        )
        XCTAssertNotNil(UUID(uuidString: sessionID))
        XCTAssertEqual(
            launchInputs.first?.socket,
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: sessionID
            )
        )
        try Data("launch".utf8).write(
            to: URL(
                fileURLWithPath: manifest.preparedAppPath,
                isDirectory: true
            ).appendingPathComponent("Info.plist")
        )
        let launchAlias =
            try PlayCoverService.createSessionLaunchAlias(
                manifest: manifest,
                sessionID: sessionID
            )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: launchAlias.bundleURL.path
            )
        )

        let lock = try XCTUnwrap(
            try SessionService.readDriverLockInfo(
                paths: fixture.paths
            )
        )
        XCTAssertEqual(lock.deviceType, "playcover")
        XCTAssertEqual(lock.deviceName, "iPhone16,2")
        XCTAssertEqual(lock.runnerPid, 4_242)
        XCTAssertEqual(lock.sessionIdentifier, sessionID)
        XCTAssertEqual(
            lock.bundleId,
            manifest.bundleIdentifier
        )
        XCTAssertEqual(
            lock.playCoverAppPath,
            manifest.preparedAppPath
        )
        XCTAssertEqual(
            lock.playCoverExecutablePath,
            manifest.executablePath
        )
        XCTAssertEqual(
            lock.playCoverGenerationKey,
            manifest.generationKey
        )
        XCTAssertEqual(
            lock.playCoverRuntimeSocketPath,
            launchInputs.first?.socket
        )
        let lockJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: URL(
                        fileURLWithPath: fixture.paths.driverLock
                    )
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(lockJSON.keys),
            Set([
                "udid",
                "deviceName",
                "deviceVersion",
                "deviceType",
                "startedAt",
                "runnerPid",
                "startMode",
                "sessionIdentifier",
                "bundleId",
                "playcoverAppPath",
                "playcoverExecutablePath",
                "playcoverGenerationKey",
                "playcoverRuntimeSocketPath",
            ])
        )
        let attributes = try FileManager.default
            .attributesOfItem(atPath: fixture.paths.driverLock)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?
                .intValue,
            0o600
        )

        let stop = cli.run(arguments: ["stop"])

        XCTAssertEqual(stop.exitCode, 0, stop.stderr)
        XCTAssertEqual(
            stop.stdout,
            "PlayCover App stopped (pid 4242)\n"
                + "PlayCover session stopped\n"
        )
        XCTAssertEqual(
            terminatedSession?.sessionIdentifier,
            sessionID
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: launchAlias.bundleURL.path
            )
        )
        XCTAssertEqual(
            fastVerificationPaths,
            [
                manifest.preparedAppPath,
                manifest.preparedAppPath,
            ]
        )
    }

    func testLoggedStartStoresReportsAndRetainsOwnerOnlyLog()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        var launchedLog: PlayCoverStdioLogIdentity?
        PlayCoverSessionService.launchOverrideForTesting = {
            _, sessionID, socketPath, stdioLog, _ in
            let stdioLog = try XCTUnwrap(stdioLog)
            launchedLog = stdioLog
            return self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socketPath,
                logPath: stdioLog.path,
                reused: true
            )
        }
        PlayCoverSessionService.terminateOverrideForTesting = {
            Int32($0.runnerPid ?? 0)
        }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        )

        let start = cli.run(
            arguments: ["start", "--playcover", "--log"]
        )

        XCTAssertEqual(start.exitCode, 0, start.stderr)
        let log = try XCTUnwrap(launchedLog)
        XCTAssertTrue(
            start.stdout.contains("PlayCover log: \(log.path)")
        )
        var fileStatus = stat()
        XCTAssertEqual(lstat(log.path, &fileStatus), 0)
        XCTAssertEqual(fileStatus.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(fileStatus.st_mode & 0o7777, 0o600)
        XCTAssertEqual(fileStatus.st_uid, geteuid())
        XCTAssertEqual(fileStatus.st_nlink, 1)
        XCTAssertEqual(
            UInt64(truncatingIfNeeded: fileStatus.st_dev),
            log.device
        )
        XCTAssertEqual(UInt64(fileStatus.st_ino), log.inode)
        var directoryStatus = stat()
        XCTAssertEqual(
            lstat(fixture.paths.playcoverLogs, &directoryStatus),
            0
        )
        XCTAssertEqual(directoryStatus.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(directoryStatus.st_mode & 0o7777, 0o700)

        let lock = try XCTUnwrap(
            try SessionService.readDriverLockInfo(
                paths: fixture.paths
            )
        )
        XCTAssertEqual(lock.playCoverLogPath, log.path)
        let lockJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: URL(
                        fileURLWithPath: fixture.paths.driverLock
                    )
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            lockJSON["playcoverLogPath"] as? String,
            log.path
        )
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .running(
                executablePath: manifest.executablePath
            )
        }
        StatusService.playCoverDiagnosticsForTesting = { _ in
            self.makeRuntimePayload(
                manifest: manifest,
                stdio: .init(
                    status: "redirected",
                    path: log.path,
                    device: log.device,
                    inode: log.inode,
                    failureStage: nil,
                    errorNumber: nil
                )
            )
        }
        let status = try StatusService.status(paths: fixture.paths)
        XCTAssertTrue(status.contains("runtime: healthy"))
        XCTAssertTrue(status.contains("stdio log: \(log.path)"))
        guard case .object(let root) =
                StatusService.machineSnapshot(
                    paths: fixture.paths
                ).data,
              case .object(let driver)? = root["driver"],
              case .string(let machineLog)? =
                driver["playcoverLogPath"],
              case .object(let runtime)? = driver["runtime"],
              case .object(let stdio)? = runtime["stdio"] else {
            return XCTFail(
                "machine status omitted PlayCover stdio evidence"
            )
        }
        XCTAssertEqual(machineLog, log.path)
        XCTAssertEqual(stdio["status"], .string("redirected"))
        let handle = try FileHandle(
            forWritingTo: URL(fileURLWithPath: log.path)
        )
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data("retained-marker\n".utf8)
        )
        try handle.close()

        let stop = cli.run(arguments: ["stop"])

        XCTAssertEqual(stop.exitCode, 0, stop.stderr)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: log.path)
        )
        XCTAssertTrue(
            try String(contentsOfFile: log.path)
                .contains("retained-marker")
        )
    }

    func testDeletedLoggedSessionLeafDoesNotBlockStop() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        var logPath: String?
        var logIdentity: PlayCoverStdioLogIdentity?
        PlayCoverSessionService.launchOverrideForTesting = {
            _, sessionID, socketPath, stdioLog, _ in
            let stdioLog = try XCTUnwrap(stdioLog)
            logPath = stdioLog.path
            logIdentity = stdioLog
            return self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socketPath,
                logPath: stdioLog.path,
                reused: true
            )
        }
        PlayCoverSessionService.terminateOverrideForTesting = {
            Int32($0.runnerPid ?? 0)
        }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        )
        XCTAssertEqual(
            cli.run(
                arguments: ["start", "--playcover", "--log"]
            ).exitCode,
            0
        )
        let path = try XCTUnwrap(logPath)
        try FileManager.default.removeItem(atPath: path)
        let identity = try XCTUnwrap(logIdentity)
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .running(
                executablePath: manifest.executablePath
            )
        }
        StatusService.playCoverDiagnosticsForTesting = { _ in
            self.makeRuntimePayload(
                manifest: manifest,
                stdio: .init(
                    status: "redirected",
                    path: identity.path,
                    device: identity.device,
                    inode: identity.inode,
                    failureStage: nil,
                    errorNumber: nil
                )
            )
        }

        let status = try StatusService.status(paths: fixture.paths)

        XCTAssertTrue(status.contains("runtime: unhealthy"))
        XCTAssertTrue(
            status.contains(
                "stdio log path no longer identifies"
            )
        )

        let stop = cli.run(arguments: ["stop"])

        XCTAssertEqual(stop.exitCode, 0, stop.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testLoggedLaunchFailureReportsAndRetainsLog() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        var logPath: String?
        PlayCoverSessionService.launchOverrideForTesting = {
            _, _, _, stdioLog, _ in
            logPath = try XCTUnwrap(stdioLog).path
            throw PlayCoverBackendError.launchFailed(
                "fixture launch failure"
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(
            arguments: ["start", "--playcover", "--log"]
        )

        XCTAssertEqual(result.exitCode, 1)
        let path = try XCTUnwrap(logPath)
        XCTAssertTrue(result.stderr.contains("fixture launch failure"))
        XCTAssertTrue(result.stderr.contains("PlayCover log: \(path)"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testStdioLogCreationRejectsSymlinkDirectoryAndCollision()
        throws
    {
        let symlinkFixture = try SessionFixture()
        defer { symlinkFixture.remove() }
        let outside = symlinkFixture.root + "/outside-logs"
        try FileManager.default.createDirectory(
            atPath: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            atPath: symlinkFixture.paths.playcoverLogs,
            withDestinationPath: outside
        )
        XCTAssertThrowsError(
            try PlayCoverStdioLogService.create(
                sessionID: UUID().uuidString,
                paths: symlinkFixture.paths
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: outside
            ),
            []
        )

        let collisionFixture = try SessionFixture()
        defer { collisionFixture.remove() }
        let sessionID = UUID().uuidString
        let first = try PlayCoverStdioLogService.create(
            sessionID: sessionID,
            paths: collisionFixture.paths
        )
        var before = stat()
        XCTAssertEqual(lstat(first.path, &before), 0)

        XCTAssertThrowsError(
            try PlayCoverStdioLogService.create(
                sessionID: sessionID,
                paths: collisionFixture.paths
            )
        )

        var after = stat()
        XCTAssertEqual(lstat(first.path, &after), 0)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
    }

    func testBareReuseRejectsFastManifestIdentityMismatch()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        let other = try makeManifest(
            fixture: fixture,
            generationKey: String(repeating: "b", count: 64)
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in other
        }
        PlayCoverSessionService.launchOverrideForTesting = {
            _, _, _, _, _ in
            XCTFail("mismatched reference must not launch")
            throw PlayCoverBackendError.launchFailed(
                "unexpected launch"
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["start", "--playcover"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "selected generation identity changed before launch"
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testBareStartNeverRefreshesDeletedSourceApp() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        PlayCoverManagedAppService.inspectOverrideForTesting = {
            _ in
            XCTFail("bare start must not inspect the source App")
            throw PlayCoverBackendError.invalidApp("unexpected inspect")
        }
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            _, _, _, _ in
            XCTFail("bare start must not prepare a generation")
            throw PlayCoverBackendError.prepareFailed(
                "unexpected prepare"
            )
        }
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.launchOverrideForTesting = {
            _, sessionID, socketPath, _, _ in
            self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socketPath,
                reused: true
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["start", "--playcover"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("generation reused:"))
    }

    func testFailedExplicitSelectionDoesNotReplaceGoodReference()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let good = try makeManifest(fixture: fixture)
        let selected = try makeManifest(
            fixture: fixture,
            generationKey: String(repeating: "b", count: 64)
        )
        try fixture.createManagedApp(manifest: good)
        try fixture.createManagedApp(manifest: selected)
        try fixture.createPreparedSidecars(manifest: selected)
        try PlayCoverSessionService.recordPrepared(
            good,
            paths: fixture.paths
        )
        PlayCoverManagedAppService.readManifestOverrideForTesting = {
            _ in selected
        }
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in
            throw PlayCoverBackendError.cacheTampered(
                "selected generation is corrupt"
            )
        }
        PlayCoverSessionService.launchOverrideForTesting = {
            _, _, _, _, _ in
            XCTFail("corrupt selection must not launch")
            throw PlayCoverBackendError.launchFailed(
                "unexpected launch"
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(
            arguments: [
                "start",
                "--playcover",
                "--app",
                selected.preparedAppPath,
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "selected generation is corrupt"
            )
        )
        XCTAssertEqual(
            try PlayCoverSessionService.readPreparedReference(
                paths: fixture.paths
            )?.generationKey,
            good.generationKey
        )
    }

    func testFailedExplicitLaunchSelectsVerifiedGeneration()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let good = try makeManifest(fixture: fixture)
        let selected = try makeManifest(
            fixture: fixture,
            generationKey: String(repeating: "b", count: 64)
        )
        try fixture.createManagedApp(manifest: good)
        try fixture.createManagedApp(manifest: selected)
        try fixture.createPreparedSidecars(manifest: selected)
        try PlayCoverSessionService.recordPrepared(
            good,
            paths: fixture.paths
        )
        PlayCoverManagedAppService.readManifestOverrideForTesting = {
            _ in selected
        }
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in selected
        }
        PlayCoverSessionService.launchOverrideForTesting = {
            _, _, _, _, _ in
            throw PlayCoverBackendError.launchFailed(
                "Runtime hello was not authenticated"
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(
            arguments: [
                "start",
                "--playcover",
                "--app",
                selected.preparedAppPath,
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "Runtime hello was not authenticated"
            )
        )
        XCTAssertEqual(
            try PlayCoverSessionService.readPreparedReference(
                paths: fixture.paths
            )?.generationKey,
            selected.generationKey
        )
    }

    func testFailedExplicitLaunchCreatesSelectorForBareRetry()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let selected = try makeManifest(
            fixture: fixture,
            generationKey: String(repeating: "b", count: 64)
        )
        try fixture.createManagedApp(manifest: selected)
        try fixture.createPreparedSidecars(manifest: selected)
        PlayCoverManagedAppService.readManifestOverrideForTesting = {
            _ in selected
        }
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in selected
        }
        var launchAttemptCount = 0
        PlayCoverSessionService.launchOverrideForTesting = {
            appPath,
            sessionID,
            socketPath,
            _,
            _ in
            XCTAssertEqual(appPath, selected.preparedAppPath)
            launchAttemptCount += 1
            if launchAttemptCount == 1 {
                throw PlayCoverBackendError.launchFailed(
                    "Runtime hello was not authenticated"
                )
            }
            return self.makeLaunchResult(
                manifest: selected,
                sessionID: sessionID,
                socketPath: socketPath,
                reused: true
            )
        }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        )

        let failed = cli.run(
            arguments: [
                "start",
                "--playcover",
                "--app",
                selected.preparedAppPath,
            ]
        )

        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertTrue(
            failed.stderr.contains(
                "Runtime hello was not authenticated"
            )
        )
        XCTAssertEqual(
            try PlayCoverSessionService.readPreparedReference(
                paths: fixture.paths
            )?.generationKey,
            selected.generationKey
        )

        let retry = cli.run(arguments: ["start", "--playcover"])

        XCTAssertEqual(retry.exitCode, 0, retry.stderr)
        XCTAssertTrue(retry.stdout.contains("generation reused:"))
        XCTAssertTrue(retry.stdout.contains(selected.generationKey))
        XCTAssertEqual(launchAttemptCount, 2)
    }

    func testLastPreparedSymlinkFailsClosed() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        let reference = URL(
            fileURLWithPath: fixture.paths.playcoverLastPrepared
        )
        let saved = reference.deletingLastPathComponent()
            .appendingPathComponent("saved-last-prepared")
        try FileManager.default.moveItem(at: reference, to: saved)
        try FileManager.default.createSymbolicLink(
            at: reference,
            withDestinationURL: saved
        )

        XCTAssertThrowsError(
            try PlayCoverSessionService.readPreparedReference(
                paths: fixture.paths
            )
        )
    }

    func testLastPreparedFIFOIsRejectedWithoutBlocking() throws {
        #if canImport(Darwin)
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            atPath: fixture.paths.playcover,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(
            mkfifo(fixture.paths.playcoverLastPrepared, 0o600),
            0
        )
        let finished = DispatchSemaphore(value: 0)
        let result = LockedReferenceResult()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try PlayCoverSessionService.readPreparedReference(
                    paths: fixture.paths
                )
                result.set(.success(()))
            } catch {
                result.set(.failure(error))
            }
            finished.signal()
        }

        XCTAssertEqual(
            finished.wait(timeout: .now() + 1),
            .success,
            "last-prepared FIFO must fail without waiting for a writer"
        )
        guard case .failure? = result.value else {
            return XCTFail("hostile last-prepared FIFO was accepted")
        }
        #else
        throw XCTSkip("FIFO verification is Darwin-only")
        #endif
    }

    func testStartRejectsExistingSessionBeforeLaunching() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try SessionService.writeDriverLock(
            info: .init(
                udid: "SIM-1",
                deviceName: "Simulator",
                deviceVersion: "26.0",
                deviceType: "simulator"
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.launchOverrideForTesting = {
            _, _, _, _, _ in
            XCTFail("existing session must block launch")
            throw PlayCoverBackendError.launchFailed(
                "unexpected launch"
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(
            arguments: [
                "start",
                "--playcover",
                "--app",
                "/tmp/Other.app",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "Driver already started for SIM-1"
            )
        )
    }

    func testFailedLockWriteTerminatesExactLaunchedSession()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        var launched: PlayCoverSessionService.LaunchResult?
        PlayCoverSessionService.launchOverrideForTesting = {
            _, sessionID, socketPath, stdioLog, _ in
            let stdioLog = try XCTUnwrap(stdioLog)
            let result = self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socketPath,
                logPath: stdioLog.path,
                reused: true
            )
            launched = result
            return result
        }
        var terminated: SessionService.Info?
        PlayCoverSessionService.terminateOverrideForTesting = {
            terminated = $0
            return Int32($0.runnerPid ?? 0)
        }
        try Data("not-a-directory".utf8).write(
            to: URL(
                fileURLWithPath:
                    fixture.root + "/state"
            )
        )

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["start", "--playcover", "--log"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(
            terminated?.sessionIdentifier,
            launched?.sessionID
        )
        XCTAssertEqual(
            terminated?.playCoverRuntimeSocketPath,
            launched?.runtimeSocketPath
        )
        XCTAssertEqual(
            terminated?.playCoverLogPath,
            launched?.logPath
        )
        let launchedLogPath = try XCTUnwrap(launched?.logPath)
        XCTAssertTrue(
            result.stderr.contains(
                "PlayCover log: \(launchedLogPath)"
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: launchedLogPath
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testFailedLockWriteAndRollbackKeepsFatalMachineOwnership()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        var launched: PlayCoverSessionService.LaunchResult?
        PlayCoverSessionService.launchOverrideForTesting = {
            _, sessionID, socketPath, stdioLog, _ in
            let stdioLog = try XCTUnwrap(stdioLog)
            let result = self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socketPath,
                logPath: stdioLog.path,
                reused: true
            )
            launched = result
            return result
        }
        PlayCoverSessionService.terminateOverrideForTesting = {
            _ in
            throw PlayCoverBackendError.terminateFailed(
                "exact process is still running"
            )
        }
        try Data("not-a-directory".utf8).write(
            to: URL(
                fileURLWithPath:
                    fixture.root + "/state"
            )
        )

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(
            arguments: [
                "start",
                "--playcover",
                "--log",
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(result.stderr.utf8)
            ) as? [String: Any]
        )
        let error = try XCTUnwrap(
            envelope["error"] as? [String: Any]
        )
        XCTAssertEqual(
            error["code"] as? String,
            "playcover_session_commit_rollback_failed"
        )
        XCTAssertEqual(
            error["phase"] as? String,
            "playcover_session_commit"
        )
        XCTAssertEqual(error["fatal"] as? Bool, true)
        XCTAssertEqual(
            error["mutationMayHaveApplied"] as? Bool,
            true
        )
        let data = try XCTUnwrap(
            envelope["data"] as? [String: Any]
        )
        let logPath = try XCTUnwrap(launched?.logPath)
        XCTAssertEqual(
            data["playcoverLogPath"] as? String,
            logPath
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: logPath)
        )
    }

    func testUnterminatedLaunchFailurePreservesExactSessionLock()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        var expected: PlayCoverSessionService.LaunchResult?
        PlayCoverSessionService.launchOverrideForTesting = {
            _, sessionID, socketPath, stdioLog, _ in
            let stdioLog = try XCTUnwrap(stdioLog)
            let result = self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socketPath,
                logPath: stdioLog.path,
                reused: true
            )
            expected = result
            throw PlayCoverSessionUnterminatedLaunchError(
                result: result,
                underlying: PlayCoverUnterminatedLaunchError(
                    sessionID: sessionID,
                    pid: result.pid,
                    bundleIdentifier:
                        result.bundleIdentifier,
                    executablePath: result.executablePath,
                    appPath: result.appPath,
                    generationKey: result.generationKey,
                    runtimeSocketPath:
                        result.runtimeSocketPath,
                    originalError: "hello timeout",
                    rollbackError:
                        "process still running after SIGKILL"
                )
            )
        }
        PlayCoverSessionService.terminateOverrideForTesting = {
            _ in
            XCTFail(
                "an unconfirmed rollback must preserve a lock, "
                    + "not pretend the process stopped"
            )
            return 0
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["start", "--playcover", "--log"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "active session lock must be preserved"
            )
        )
        let lock = try XCTUnwrap(
            try SessionService.readDriverLockInfo(
                paths: fixture.paths
            )
        )
        XCTAssertEqual(lock.runnerPid, Int(expected?.pid ?? 0))
        XCTAssertEqual(
            lock.sessionIdentifier,
            expected?.sessionID
        )
        XCTAssertEqual(
            lock.playCoverRuntimeSocketPath,
            expected?.runtimeSocketPath
        )
        XCTAssertEqual(
            lock.playCoverLogPath,
            expected?.logPath
        )
        let expectedLogPath = try XCTUnwrap(expected?.logPath)
        XCTAssertTrue(
            result.stderr.contains(
                "PlayCover log: \(expectedLogPath)"
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: expectedLogPath
            )
        )
    }

    func testCorruptedLockCannotRedirectSocketAppOrExecutable()
        throws
    {
        for mutation in LockMutation.allCases {
            let fixture = try SessionFixture()
            defer { fixture.remove() }
            let manifest = try makeManifest(fixture: fixture)
            try fixture.createManagedApp(manifest: manifest)
            let sessionID = UUID().uuidString
            let expectedSocket =
                try fixture.paths.playCoverRuntimeSocketPath(
                    sessionID: sessionID
                )
            var info = makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: expectedSocket
            )
            switch mutation {
            case .socket:
                info = replacing(
                    info,
                    runtimeSocketPath: fixture.root
                        + "/other.sock"
                )
            case .app:
                info = replacing(
                    info,
                    appPath: fixture.root + "/Outside.app"
                )
            case .executable:
                info = replacing(
                    info,
                    executablePath: "/bin/false"
                )
            case .log:
                info = replacing(
                    info,
                    logPath: fixture.root + "/outside.log"
                )
            }
            try SessionService.writeDriverLock(
                info: info,
                paths: fixture.paths
            )

            XCTAssertThrowsError(
                try SessionService.readDriverLockInfo(
                    paths: fixture.paths
                )
            ) { error in
                let text = String(describing: error)
                switch mutation {
                case .socket:
                    XCTAssertTrue(
                        text.contains(
                            "socket does not match its sessionID"
                        )
                    )
                case .app:
                    XCTAssertTrue(
                        text.contains(
                            "not the recorded generation"
                        )
                    )
                case .executable:
                    XCTAssertTrue(
                        text.contains(
                            "executable is outside"
                        )
                    )
                case .log:
                    XCTAssertTrue(
                        text.contains(
                            "stdio log path does not match"
                        )
                    )
                }
            }
        }
    }

    func testTerminateRefusesPIDWhoseExecutableChanged() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService
            .processExecutablePathOverrideForTesting = {
                XCTAssertEqual($0, 4_242)
                return "/bin/false"
            }
        var signalCount = 0
        PlayCoverSessionService.signalOverrideForTesting = {
            _, _ in
            signalCount += 1
            return 0
        }
        let sessionID = UUID().uuidString
        let session = makeSessionInfo(
            manifest: manifest,
            sessionID: sessionID,
            socketPath:
                try fixture.paths.playCoverRuntimeSocketPath(
                    sessionID: sessionID
                )
        )

        XCTAssertThrowsError(
            try PlayCoverSessionService.terminate(
                session: session
            )
        ) {
            guard case .terminateFailed(let message) =
                    $0 as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(
                message.contains("different executable")
            )
        }
        XCTAssertEqual(signalCount, 0)
    }

    func testStopPreservesLockWhenProcessIdentityIsUnverifiable()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            XCTAssertEqual($0, 4_242)
            return .unverifiable(errno: EACCES)
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("cannot verify"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testStopRefusesSameExecutablePIDReuseWithoutSessionProof()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .running(
                executablePath: manifest.executablePath
            )
        }
        PlayCoverSessionService
            .terminationIdentityProbeOverrideForTesting = { _ in
                throw PlayCoverRuntimeClientError
                    .sessionIDMismatch
            }
        var signalCount = 0
        PlayCoverSessionService.signalOverrideForTesting = {
            _, _ in
            signalCount += 1
            return 0
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "did not prove the recorded "
                    + "sessionID/PID/bundle/executable identity"
            )
        )
        XCTAssertEqual(signalCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testStopTerminatesWedgedRuntimeOnlyWithExactOfflineIdentity()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        let recordedStart = 1_800_000_000_000
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    ),
                startedAt: recordedStart
            ),
            paths: fixture.paths
        )
        var verifiedPaths: [String] = []
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            verifiedPaths.append($0)
            return manifest
        }
        var processProbeCount = 0
        PlayCoverSessionService.processStateOverrideForTesting = {
            pid in
            XCTAssertEqual(pid, 4_242)
            processProbeCount += 1
            if processProbeCount <= 2 {
                return .running(
                    executablePath: manifest.executablePath
                )
            }
            return .missing
        }
        let processBirth =
            UInt64(recordedStart - 1_000) * 1_000
        PlayCoverSessionService
            .processStartTimeOverrideForTesting = { pid in
                XCTAssertEqual(pid, 4_242)
                return processBirth
            }
        PlayCoverSessionService
            .terminationIdentityProbeOverrideForTesting = {
                _ in
                throw PlayCoverRuntimeClientError.timeout(
                    operation: "read"
                )
            }
        var signals: [Int32] = []
        PlayCoverSessionService.signalOverrideForTesting = {
            pid,
            signal in
            XCTAssertEqual(pid, 4_242)
            signals.append(signal)
            return 0
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(signals, [SIGTERM])
        XCTAssertEqual(
            verifiedPaths,
            [
                manifest.preparedAppPath,
                manifest.preparedAppPath,
            ]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testWedgedStopRefusesSameExecutablePIDReuse()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        let recordedStart = 1_800_000_000_000
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    ),
                startedAt: recordedStart
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .running(
                executablePath: manifest.executablePath
            )
        }
        var birthProbeCount = 0
        let replacementBirth =
            UInt64(recordedStart + 1_000) * 1_000
        PlayCoverSessionService
            .processStartTimeOverrideForTesting = { _ in
                birthProbeCount += 1
                return replacementBirth
            }
        PlayCoverSessionService
            .terminationIdentityProbeOverrideForTesting = {
                _ in
                throw PlayCoverRuntimeClientError.timeout(
                    operation: "read"
                )
            }
        var signalCount = 0
        PlayCoverSessionService.signalOverrideForTesting = {
            _, _ in
            signalCount += 1
            return 0
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "stable process birth identity does not match "
                    + "the recorded session"
            )
        )
        XCTAssertEqual(birthProbeCount, 2)
        XCTAssertEqual(signalCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testOfflineStopFallbackRejectsIdentityAndProtocolErrors() {
        let refused: [PlayCoverRuntimeClientError] = [
            .peerPIDMismatch(expected: 4_242, actual: 4_243),
            .processExecutableMismatch,
            .sessionIDMismatch,
            .responseIdentityMismatch("PID"),
            .unsupportedSchemaVersion(99),
            .malformedResponse("invalid envelope"),
        ]
        for error in refused {
            XCTAssertFalse(
                PlayCoverService
                    .permitsUnresponsiveRuntimeTermination(
                        after: error
                    ),
                "\(error)"
            )
        }

        let unavailable: [PlayCoverRuntimeClientError] = [
            .connectFailed(errno: ECONNREFUSED),
            .timeout(operation: "read"),
            .unexpectedEOF(
                operation: "read",
                expectedBytes: 4,
                receivedBytes: 0
            ),
        ]
        for error in unavailable {
            XCTAssertTrue(
                PlayCoverService
                    .permitsUnresponsiveRuntimeTermination(
                        after: error
                    ),
                "\(error)"
            )
        }
    }

    func testWedgedStopRefusesTamperedGeneration()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        let tampered = try makeManifest(
            fixture: fixture,
            generationKey: String(repeating: "b", count: 64)
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in tampered
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in
            XCTFail("tampered generation must fail before PID IO")
            return .missing
        }
        var signalCount = 0
        PlayCoverSessionService.signalOverrideForTesting = {
            _, _ in
            signalCount += 1
            return 0
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "no longer matches the exact prepared App generation"
            )
        )
        XCTAssertEqual(signalCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testStopSignalsOnlyAfterLiveSessionIdentityProof()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        let session = makeSessionInfo(
            manifest: manifest,
            sessionID: sessionID,
            socketPath:
                try fixture.paths.playCoverRuntimeSocketPath(
                    sessionID: sessionID
                )
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        var processProbeCount = 0
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in
            processProbeCount += 1
            if processProbeCount <= 2 {
                return .running(
                    executablePath: manifest.executablePath
                )
            }
            return .missing
        }
        var identityProbeCount = 0
        PlayCoverSessionService
            .terminationIdentityProbeOverrideForTesting = { info in
                identityProbeCount += 1
                XCTAssertEqual(
                    info.sessionIdentifier,
                    sessionID
                )
            }
        var signals: [Int32] = []
        PlayCoverSessionService.signalOverrideForTesting = {
            pid,
            signal in
            XCTAssertEqual(pid, 4_242)
            signals.append(signal)
            return 0
        }

        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: session
            ),
            4_242
        )
        XCTAssertEqual(identityProbeCount, 1)
        XCTAssertEqual(signals, [SIGTERM])
    }

    func testStopTreatsPostSIGTERMESRCHVerificationAsExit()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        var processProbeCount = 0
        PlayCoverSessionService.processStateOverrideForTesting = {
            pid in
            XCTAssertEqual(pid, 4_242)
            processProbeCount += 1
            switch processProbeCount {
            case 1, 2:
                return .running(
                    executablePath: manifest.executablePath
                )
            case 3:
                return .unverifiable(errno: ESRCH)
            default:
                XCTFail("stop must finish on post-SIGTERM ESRCH")
                return .missing
            }
        }
        var birthProbeCount = 0
        PlayCoverSessionService
            .processStartTimeOverrideForTesting = { pid in
                XCTAssertEqual(pid, 4_242)
                birthProbeCount += 1
                return 1_800_000_000_000_000
            }
        var identityProbeCount = 0
        PlayCoverSessionService
            .terminationIdentityProbeOverrideForTesting = { info in
                identityProbeCount += 1
                XCTAssertEqual(
                    info.sessionIdentifier,
                    sessionID
                )
            }
        var signals: [Int32] = []
        PlayCoverSessionService.signalOverrideForTesting = {
            pid,
            signal in
            XCTAssertEqual(pid, 4_242)
            signals.append(signal)
            return 0
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(processProbeCount, 3)
        XCTAssertEqual(birthProbeCount, 2)
        XCTAssertEqual(identityProbeCount, 1)
        XCTAssertEqual(signals, [SIGTERM])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testStopClearsLockOnlyForConfirmedESRCH() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .missing
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
    }

    func testActiveBackendRejectsEveryAppLifecycleCommandBeforeDriverIO()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        IOSUseCLI.playCoverDriverClientFactoryForTesting = { _ in
            XCTFail("lifecycle routing must not create a Runtime client")
            return self.makeClientThatMustNotRun()
        }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        )

        for arguments in [
            ["activateApp", manifest.bundleIdentifier],
            ["terminateApp", manifest.bundleIdentifier],
            ["home"],
        ] {
            let result = cli.run(arguments: arguments)
            XCTAssertEqual(result.exitCode, 1, "\(arguments)")
            XCTAssertTrue(
                result.stderr.contains(
                    "use `ios-use start --playcover` "
                        + "and `ios-use stop`"
                ),
                result.stderr
            )
        }
    }

    func testInvalidPlayCoverLockBlocksRoutingBeforeRealDeviceIO()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: URL(
                fileURLWithPath: fixture.paths.driverLock
            ).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: [
                "udid": "playcover:corrupt",
                "deviceType": "playcover",
                "startedAt": 1,
            ]
        ).write(
            to: URL(
                fileURLWithPath: fixture.paths.driverLock
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.paths.driverLock
        )
        var deviceLookupCount = 0
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            deviceLookupCount += 1
            return [
                IOSDevice(
                    name: "Must Not Be Used",
                    version: "26.0",
                    udid: "REAL-DEVICE",
                    kind: .real
                ),
            ]
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root]
        ).run(arguments: ["open", "https://example.com"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "Invalid driver.lock: incomplete PlayCover session"
            )
        )
        XCTAssertEqual(deviceLookupCount, 0)
    }

    func testStatusClassifiesMissingExactProcessAsStaleWithoutRuntimeIO()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.processStateOverrideForTesting = {
            XCTAssertEqual($0, 4_242)
            return .missing
        }
        StatusService.playCoverDiagnosticsForTesting = { _ in
            XCTFail("stale PID must not contact Runtime")
            throw CLIParseError.invalidValue(
                "unexpected diagnostics"
            )
        }

        let text = try StatusService.status(
            paths: fixture.paths
        )

        XCTAssertTrue(text.contains("runtime: stale"))
        XCTAssertTrue(
            text.contains(
                "recorded App process is not running"
            )
        )
    }

    func testStatusAcceptsLegacyUnloggedRuntimeWithoutStdioEvidence()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .running(
                executablePath: manifest.executablePath
            )
        }
        StatusService.playCoverDiagnosticsForTesting = { _ in
            self.makeRuntimePayload(
                manifest: manifest,
                stdio: nil
            )
        }

        let text = try StatusService.status(paths: fixture.paths)

        XCTAssertTrue(text.contains("runtime: healthy"))
        guard case .object(let root) =
                StatusService.machineSnapshot(
                    paths: fixture.paths
                ).data,
              case .object(let driver)? = root["driver"],
              case .object(let runtime)? = driver["runtime"] else {
            return XCTFail("legacy Runtime status is incomplete")
        }
        XCTAssertEqual(runtime["stdio"], .null)
    }

    func testStatusKeepsUnverifiableLiveProcessUnhealthy()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.processStateOverrideForTesting = {
            XCTAssertEqual($0, 4_242)
            return .unverifiable(errno: EACCES)
        }
        StatusService.playCoverDiagnosticsForTesting = { _ in
            XCTFail("unverified PID must not contact Runtime")
            throw CLIParseError.invalidValue(
                "unexpected diagnostics"
            )
        }

        let text = try StatusService.status(
            paths: fixture.paths
        )

        XCTAssertTrue(text.contains("runtime: unhealthy"))
        XCTAssertTrue(
            text.contains(
                "cannot verify recorded App process identity: errno 13"
            )
        )
        let snapshot = StatusService.machineSnapshot(
            paths: fixture.paths
        ).data
        XCTAssertEqual(
            runtimeIdentityVerified(snapshot),
            false
        )
    }

    func testUnhealthyStatusReportsIdentityVerifiedOnlyAfterRuntimeIdentity()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: makeSessionInfo(
                manifest: manifest,
                sessionID: sessionID,
                socketPath:
                    try fixture.paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: fixture.paths
        )
        DeviceService.listDevicesOverrideForTesting = { _, _ in [] }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .running(
                executablePath: manifest.executablePath
            )
        }
        StatusService.playCoverDiagnosticsForTesting = { _ in
            throw CLIParseError.invalidValue("transport timeout")
        }

        let beforeIdentity = StatusService.machineSnapshot(
            paths: fixture.paths
        ).data
        XCTAssertEqual(
            runtimeIdentityVerified(beforeIdentity),
            false
        )

        StatusService.playCoverDiagnosticsForTesting = { _ in
            self.makeRuntimePayload(
                manifest: manifest,
                logicalWidth: 431
            )
        }
        let afterIdentity = StatusService.machineSnapshot(
            paths: fixture.paths
        ).data
        XCTAssertEqual(
            runtimeIdentityVerified(afterIdentity),
            true
        )

        StatusService.playCoverDiagnosticsForTesting = { _ in
            self.makeRuntimePayload(
                manifest: manifest,
                hostPolicy: false
            )
        }
        let hostMismatch = StatusService.machineSnapshot(
            paths: fixture.paths
        ).data
        XCTAssertEqual(
            runtimeIdentityVerified(hostMismatch),
            true
        )
        let hostMismatchText = try StatusService.status(paths: fixture.paths)
        XCTAssertTrue(hostMismatchText.contains("runtime: unhealthy"))
        XCTAssertTrue(
            hostMismatchText.contains(
                "simulator-scale host policy"
            )
        )

        StatusService.playCoverDiagnosticsForTesting = { _ in
            self.makeRuntimePayload(
                manifest: manifest,
                hostCaptureError: "canvas capture unavailable"
            )
        }
        let captureMismatch = StatusService.machineSnapshot(
            paths: fixture.paths
        ).data
        XCTAssertEqual(
            runtimeIdentityVerified(captureMismatch),
            true
        )
        guard case .object(let captureRoot) = captureMismatch,
              case .object(let captureDriver)? = captureRoot["driver"],
              case .object(let captureRuntime)? = captureDriver["runtime"],
              case .object(let captureHost)? = captureRuntime["host"],
              case .object(let capture)? = captureHost["capture"] else {
            return XCTFail("unhealthy Runtime must retain host capture diagnostics")
        }
        XCTAssertEqual(
            capture["error"],
            .string("canvas capture unavailable")
        )
        let captureMismatchText = try StatusService.status(
            paths: fixture.paths
        )
        XCTAssertTrue(captureMismatchText.contains("runtime: unhealthy"))
        XCTAssertTrue(
            captureMismatchText.contains(
                "host capture: canvas capture unavailable"
            )
        )
    }

    func testSessionSocketNameIsDerivedAndLengthBounded()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let first = try fixture.paths
            .playCoverRuntimeSocketPath(
                sessionID:
                    "A1-\(UUID().uuidString)"
            )
        let second = try fixture.paths
            .playCoverRuntimeSocketPath(
                sessionID:
                    "B2-\(UUID().uuidString)"
        )
        XCTAssertNotEqual(first, second)
        var canonicalBuffer = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        let resolved = fixture.paths.playcoverRun.withCString {
            Darwin.realpath($0, &canonicalBuffer)
        }
        let canonicalRun = resolved.map {
            _ in String(cString: canonicalBuffer)
        } ?? fixture.paths.playcoverRun
        XCTAssertTrue(first.hasPrefix(canonicalRun))
        XCTAssertLessThanOrEqual(first.utf8.count, 103)

        let longRoot = "/tmp/"
            + String(repeating: "x", count: 95)
        let longPaths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": longRoot]
        )
        XCTAssertThrowsError(
            try longPaths.playCoverRuntimeSocketPath(
                sessionID: UUID().uuidString
            )
        )
    }

    func testLongSessionSocketPathFailsBeforeSourceInspection()
        throws
    {
        let longRoot = "/tmp/ios-use-"
            + String(repeating: "x", count: 95)
        defer {
            try? FileManager.default.removeItem(
                atPath: longRoot
            )
        }
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": longRoot]
        )
        var inspected = false
        PlayCoverManagedAppService.inspectOverrideForTesting = {
            _ in
            inspected = true
            throw PlayCoverBackendError.invalidApp(
                "source inspection must not run"
            )
        }

        XCTAssertThrowsError(
            try PlayCoverSessionService.launch(
                explicitAppPath: "/tmp/Source.app",
                timeout: 1,
                paths: paths
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "too long for a PlayCover Unix socket"
                )
            )
        }
        XCTAssertFalse(inspected)
    }

    func testLaunchPreservesUntrackedStaleRuntimeSocket()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let stalePath = runtimeSocketPath(
            in: fixture,
            token: String(repeating: "6", count: 32)
        )
        let descriptor = try bindUnixSocket(
            at: stalePath,
            type: SOCK_STREAM
        )
        Darwin.close(descriptor)
        PlayCoverManagedAppService.inspectOverrideForTesting = {
            _ in
            throw PlayCoverBackendError.invalidApp(
                "expected inspection failure"
            )
        }

        XCTAssertThrowsError(
            try PlayCoverSessionService.launch(
                explicitAppPath: "/tmp/Source.app",
                timeout: 1,
                paths: fixture.paths
            )
        )
        XCTAssertTrue(pathExists(stalePath))
    }

    func testFreshExactRuntimeSocketPathRejectsExistingObjects()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        let listenerPath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: UUID().uuidString
            )
        let listener = try bindUnixSocket(
            at: listenerPath,
            type: SOCK_STREAM,
            listening: true
        )
        defer { Darwin.close(listener) }
        let queuedClient = try connectUnixSocket(at: listenerPath)
        defer { Darwin.close(queuedClient) }
        try assertFreshSocketValidationPreservesExistingPath(
            listenerPath
        )

        let stalePath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: UUID().uuidString
            )
        let stale = try bindUnixSocket(
            at: stalePath,
            type: SOCK_STREAM
        )
        Darwin.close(stale)
        try assertFreshSocketValidationPreservesExistingPath(
            stalePath
        )

        let filePath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: UUID().uuidString
            )
        try Data("owned-by-test".utf8).write(
            to: URL(fileURLWithPath: filePath)
        )
        try assertFreshSocketValidationPreservesExistingPath(
            filePath
        )
        XCTAssertEqual(
            try String(contentsOfFile: filePath, encoding: .utf8),
            "owned-by-test"
        )

        let linkPath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: UUID().uuidString
            )
        XCTAssertEqual(
            symlink("unknown-target", linkPath),
            0
        )
        try assertFreshSocketValidationPreservesExistingPath(
            linkPath
        )
        var target = [CChar](repeating: 0, count: Int(PATH_MAX))
        let targetLength = readlink(
            linkPath,
            &target,
            target.count - 1
        )
        XCTAssertGreaterThan(targetLength, 0)
        target[Int(targetLength)] = 0
        XCTAssertEqual(String(cString: target), "unknown-target")
    }

    func testTerminateNeverUnlinksStaleLiveOrDatagramSocketPaths()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .missing
        }

        let staleSessionID = UUID().uuidString
        let stalePath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: staleSessionID
            )
        let staleDescriptor = try bindUnixSocket(
            at: stalePath,
            type: SOCK_STREAM
        )
        Darwin.close(staleDescriptor)
        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: makeSessionInfo(
                    manifest: manifest,
                    sessionID: staleSessionID,
                    socketPath: stalePath
                )
            ),
            4_242
        )
        XCTAssertTrue(pathExists(stalePath))

        let liveSessionID = UUID().uuidString
        let livePath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: liveSessionID
            )
        let liveDescriptor = try bindUnixSocket(
            at: livePath,
            type: SOCK_STREAM,
            listening: true
        )
        defer { Darwin.close(liveDescriptor) }
        let queuedClient = try connectUnixSocket(at: livePath)
        defer { Darwin.close(queuedClient) }
        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: makeSessionInfo(
                    manifest: manifest,
                    sessionID: liveSessionID,
                    socketPath: livePath
                )
            ),
            4_242
        )
        XCTAssertTrue(pathExists(livePath))

        let datagramSessionID = UUID().uuidString
        let datagramPath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: datagramSessionID
            )
        let datagramDescriptor = try bindUnixSocket(
            at: datagramPath,
            type: SOCK_DGRAM
        )
        defer { Darwin.close(datagramDescriptor) }
        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: makeSessionInfo(
                    manifest: manifest,
                    sessionID: datagramSessionID,
                    socketPath: datagramPath
                )
            ),
            4_242
        )
        XCTAssertTrue(pathExists(datagramPath))
    }

    func testTerminateDoesNotWaitForOrUnlinkListenerTeardown()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .missing
        }

        let sessionID = UUID().uuidString
        let socketPath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: sessionID
            )
        let descriptor = try bindUnixSocket(
            at: socketPath,
            type: SOCK_STREAM,
            listening: true
        )
        let listenerClosed = expectation(
            description: "listener closed"
        )
        DispatchQueue.global().asyncAfter(
            deadline: .now() + 0.25
        ) {
            Darwin.close(descriptor)
            listenerClosed.fulfill()
        }

        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: makeSessionInfo(
                    manifest: manifest,
                    sessionID: sessionID,
                    socketPath: socketPath
                )
            ),
            4_242
        )
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - started,
            0.2
        )
        wait(for: [listenerClosed], timeout: 1)
        XCTAssertTrue(pathExists(socketPath))
    }

    func testTerminatePreservesRegularAndSymlinkRuntimePaths()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .missing
        }

        let regularSessionID = UUID().uuidString
        let regularPath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: regularSessionID
            )
        try Data("preserve".utf8).write(
            to: URL(fileURLWithPath: regularPath)
        )
        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: makeSessionInfo(
                    manifest: manifest,
                    sessionID: regularSessionID,
                    socketPath: regularPath
                )
            ),
            4_242
        )
        XCTAssertEqual(
            try String(contentsOfFile: regularPath),
            "preserve"
        )

        let symlinkSessionID = UUID().uuidString
        let symlinkPath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: symlinkSessionID
            )
        let targetPath = fixture.root + "/socket-link-target"
        try Data("target".utf8).write(
            to: URL(fileURLWithPath: targetPath)
        )
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath,
            withDestinationPath: targetPath
        )
        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: makeSessionInfo(
                    manifest: manifest,
                    sessionID: symlinkSessionID,
                    socketPath: symlinkPath
                )
            ),
            4_242
        )
        XCTAssertTrue(pathExists(symlinkPath))
        XCTAssertEqual(
            try String(contentsOfFile: targetPath),
            "target"
        )
    }

    func testTerminateSucceedsWhenSocketAndRunDirectoryAreMissing()
        throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .missing
        }
        let sessionID = UUID().uuidString
        let socketPath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: sessionID
            )
        XCTAssertEqual(
            try PlayCoverSessionService.expectedRuntimeSocketPath(
                sessionID: sessionID,
                manifest: manifest
            ),
            socketPath
        )
        try FileManager.default.removeItem(
            atPath: fixture.paths.playcoverRun
        )
        XCTAssertEqual(
            try PlayCoverSessionService.expectedRuntimeSocketPath(
                sessionID: sessionID,
                manifest: manifest
            ),
            socketPath
        )

        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: makeSessionInfo(
                    manifest: manifest,
                    sessionID: sessionID,
                    socketPath: socketPath
                )
            ),
            4_242
        )
    }

    func testTerminateDoesNotMutateSocketOutsideOwnerOnlyRunDirectory()
        throws
    {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(fixture: fixture)
        try fixture.createManagedApp(manifest: manifest)
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            _ in manifest
        }
        PlayCoverSessionService.processStateOverrideForTesting = {
            _ in .missing
        }
        let sessionID = UUID().uuidString
        let socketPath =
            try fixture.paths.playCoverRuntimeSocketPath(
                sessionID: sessionID
            )
        let descriptor = try bindUnixSocket(
            at: socketPath,
            type: SOCK_STREAM
        )
        Darwin.close(descriptor)
        XCTAssertEqual(
            chmod(fixture.paths.playcoverRun, 0o755),
            0
        )

        XCTAssertEqual(
            try PlayCoverSessionService.terminate(
                session: makeSessionInfo(
                    manifest: manifest,
                    sessionID: sessionID,
                    socketPath: socketPath
                )
            ),
            4_242
        )
        XCTAssertTrue(pathExists(socketPath))
    }

    private func runtimeSocketPath(
        in fixture: SessionFixture,
        token: String
    ) -> String {
        fixture.paths.playcoverRun + "/s-\(token).sock"
    }

    private func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func assertFreshSocketValidationPreservesExistingPath(
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var before = stat()
        XCTAssertEqual(
            lstat(path, &before),
            0,
            file: file,
            line: line
        )
        XCTAssertThrowsError(
            try PlayCoverService.validateFreshRuntimeSocketPath(
                path
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "refusing an existing Runtime socket path"
                ),
                String(describing: error),
                file: file,
                line: line
            )
        }
        var after = stat()
        XCTAssertEqual(
            lstat(path, &after),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            before.st_dev,
            after.st_dev,
            file: file,
            line: line
        )
        XCTAssertEqual(
            before.st_ino,
            after.st_ino,
            file: file,
            line: line
        )
        XCTAssertEqual(
            before.st_mode,
            after.st_mode,
            file: file,
            line: line
        )
    }

    private func bindUnixSocket(
        at path: String,
        type: Int32,
        listening: Bool = false
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, type, 0)
        guard descriptor >= 0 else {
            throw posixTestError(errno)
        }
        var address: sockaddr_un
        do {
            address = try unixSocketAddress(at: path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let errorNumber = errno
            Darwin.close(descriptor)
            throw posixTestError(errorNumber)
        }
        if listening, Darwin.listen(descriptor, 1) != 0 {
            let errorNumber = errno
            Darwin.close(descriptor)
            throw posixTestError(errorNumber)
        }
        return descriptor
    }

    private func connectUnixSocket(
        at path: String
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw posixTestError(errno)
        }
        var address: sockaddr_un
        do {
            address = try unixSocketAddress(at: path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            let errorNumber = errno
            Darwin.close(descriptor)
            throw posixTestError(errorNumber)
        }
        return descriptor
    }

    private func unixSocketAddress(
        at path: String
    ) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(
            ofValue: address.sun_path
        )
        guard bytes.count + 1 <= capacity else {
            throw posixTestError(ENAMETOOLONG)
        }
        address.sun_len = UInt8(
            MemoryLayout<sockaddr_un>.size
        )
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.initializeMemory(
                as: UInt8.self,
                repeating: 0
            )
            $0.copyBytes(from: bytes)
        }
        return address
    }

    private func posixTestError(
        _ errorNumber: Int32
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorNumber)
        )
    }

    private enum LockMutation: CaseIterable {
        case socket
        case app
        case executable
        case log
    }

    private func runtimeIdentityVerified(
        _ snapshot: MachineValue
    ) -> Bool? {
        guard case .object(let root) = snapshot,
              case .object(let driver)? = root["driver"],
              case .object(let runtime)? = driver["runtime"],
              case .boolean(let verified)? =
                runtime["identityVerified"] else {
            return nil
        }
        return verified
    }

    private func makeRuntimePayload(
        manifest: PlayCoverPrepareManifest,
        logicalWidth: Double =
            Double(IOSUsePlayDeviceLogicalWidth),
        hostPolicy: Bool = true,
        hostCaptureError: String? = nil,
        stdio: PlayCoverRuntimeStdioState? = .init(
            status: "disabled",
            path: nil,
            device: nil,
            inode: nil,
            failureStage: nil,
            errorNumber: nil
        )
    ) -> PlayCoverRuntimeDiagnosticsPayload {
        .init(
            pid: 4_242,
            bundleIdentifier: manifest.bundleIdentifier,
            executablePath: manifest.executablePath,
            capabilities: ["diagnostics"],
            geometry: .init(
                logical: .init(
                    width: logicalWidth,
                    height: Double(
                        IOSUsePlayDeviceLogicalHeight
                    )
                ),
                native: .init(
                    width: Double(IOSUsePlayDeviceNativeWidth),
                    height: Double(IOSUsePlayDeviceNativeHeight)
                ),
                scale: Double(IOSUsePlayDeviceScale),
                window: .init(
                    width: Double(
                        IOSUsePlayDeviceLogicalWidth
                    ),
                    height: Double(
                        IOSUsePlayDeviceLogicalHeight
                    )
                ),
                safeArea: .init(
                    top: 17,
                    left: 3,
                    bottom: 29,
                    right: 4
                ),
                host: hostCaptureError.map {
                    makeUnavailableSimulatorScaleHostGeometry(
                        hostPolicy: hostPolicy,
                        error: $0
                    )
                } ?? makeSimulatorScaleHostGeometry(
                    hostPolicy: hostPolicy
                )
            ),
            stage: "ready",
            diagnostics: [
                "runtime": .object([
                    "stage": .string("ready"),
                ]),
            ],
            stdio: stdio
        )
    }

    private func makeSimulatorScaleHostGeometry(
        hostPolicy: Bool = true
    )
        -> PlayCoverRuntimeHostGeometry
    {
        .init(
            status: "configured",
            hostPolicy: hostPolicy,
            frame: .init(x: 40, y: 30, width: 322.5, height: 727),
            contentBounds: .init(x: 0, y: 0, width: 322.5, height: 699),
            canvasRect: .init(x: 0, y: 0, width: 322.5, height: 699),
            backingPixelCanvasRect: .init(
                x: 0,
                y: 0,
                width: 322.5,
                height: 699
            ),
            canvasBounds: .init(x: 0, y: 0, width: 430, height: 932),
            renderViewBounds: .init(
                x: 0,
                y: 0,
                width: 430,
                height: 932
            ),
            sceneRenderViewFrame: .init(
                x: 0,
                y: 0,
                width: 430,
                height: 932
            ),
            sceneRenderViewBounds: .init(
                x: 0,
                y: 0,
                width: 430,
                height: 932
            ),
            inputRenderViewFrame: .init(
                x: 0,
                y: 0,
                width: 430,
                height: 932
            ),
            inputRenderViewBounds: .init(
                x: 0,
                y: 0,
                width: 430,
                height: 932
            ),
            displayScale: 0.75,
            inverseDisplayScale: 4.0 / 3.0,
            backingScaleFactor: 2,
            halfPixelTolerance: 0.25,
            idiomScale: 1,
            windowScale: 1,
            downscaleWindowIfNecessary: false,
            opaque: true,
            publicTitleBar: true,
            titleVisible: true,
            resizable: true,
            title: "Fixture",
            titleExpected: "Fixture",
            capture: .init(
                ready: true,
                error: nil,
                hostContentCGWindowRect: .init(
                    x: 40,
                    y: 38,
                    width: 322.5,
                    height: 699
                ),
                hostCGWindowBounds: .init(
                    x: 40,
                    y: 10,
                    width: 322.5,
                    height: 727
                ),
                canvasCGWindowRect: .init(
                    x: 40,
                    y: 38,
                    width: 322.5,
                    height: 699
                ),
                hostWindowNumber: 17
            )
        )
    }

    private func makeUnavailableSimulatorScaleHostGeometry(
        hostPolicy: Bool,
        error: String
    ) -> PlayCoverRuntimeHostGeometry {
        let host = makeSimulatorScaleHostGeometry(
            hostPolicy: hostPolicy
        )
        return .init(
            status: host.status,
            hostPolicy: host.hostPolicy,
            frame: host.frame,
            contentBounds: host.contentBounds,
            canvasRect: host.canvasRect,
            backingPixelCanvasRect:
                host.backingPixelCanvasRect,
            canvasBounds: host.canvasBounds,
            renderViewBounds: host.renderViewBounds,
            sceneRenderViewFrame: host.sceneRenderViewFrame,
            sceneRenderViewBounds: host.sceneRenderViewBounds,
            inputRenderViewFrame: host.inputRenderViewFrame,
            inputRenderViewBounds: host.inputRenderViewBounds,
            displayScale: host.displayScale,
            inverseDisplayScale: host.inverseDisplayScale,
            backingScaleFactor: host.backingScaleFactor,
            halfPixelTolerance: host.halfPixelTolerance,
            idiomScale: host.idiomScale,
            windowScale: host.windowScale,
            downscaleWindowIfNecessary:
                host.downscaleWindowIfNecessary,
            opaque: host.opaque,
            publicTitleBar: host.publicTitleBar,
            titleVisible: host.titleVisible,
            resizable: host.resizable,
            title: host.title,
            titleExpected: host.titleExpected,
            capture: .init(
                ready: false,
                error: error,
                hostContentCGWindowRect: .init(
                    x: 0,
                    y: 0,
                    width: 0,
                    height: 0
                ),
                hostCGWindowBounds: .init(
                    x: 0,
                    y: 0,
                    width: 0,
                    height: 0
                ),
                canvasCGWindowRect: .init(
                    x: 0,
                    y: 0,
                    width: 0,
                    height: 0
                ),
                hostWindowNumber: nil
            )
        )
    }

    private func makeManifest(
        fixture: SessionFixture,
        generationKey: String =
            String(repeating: "a", count: 64)
    ) throws -> PlayCoverPrepareManifest {
        let appPath = fixture.paths.playcoverPrepared
            + "/\(generationKey)/com.example.demo.app"
        let object: [String: Any] = [
            "schemaVersion": 3,
            "backend": "playcover-headless",
            "sourceAppPath": fixture.root + "/Source.app",
            "preparedAppPath": appPath,
            "bundleIdentifier": "com.example.demo",
            "executableName": "Demo",
            "executablePath": appPath + "/Demo",
            "sourceContentHash": String(
                repeating: "1",
                count: 64
            ),
            "sourceHashAfterPreparation": String(
                repeating: "1",
                count: 64
            ),
            "runtimeBuildHash": String(
                repeating: "2",
                count: 64
            ),
            "prepareRevision":
                PlayCoverService.prepareImplementationRevision,
            "generationKey": generationKey,
            "runtimeLoadPath": PlayCoverMachO.runtimeLoadPath,
            "runtimeFrameworkName":
                PlayCoverService.runtimeFrameworkName,
            "convertedMachOs": ["Demo"],
            "signingOrder": ["Demo"],
            "sourceInventory": [],
            "sourceMachOs": [],
            "inventory": [],
            "machOs": [],
            "entitlementDiff": [
                "original": [:],
                "playCoverBaseline": [:],
                "final": [:],
                "addedByPlayCover": [],
                "addedByIOSUse": [],
                "changedFromOriginal": [],
                "removedFromOriginal": [],
            ],
            "completedAt": "2026-07-25T00:00:00Z",
        ]
        return try JSONDecoder().decode(
            PlayCoverPrepareManifest.self,
            from: JSONSerialization.data(
                withJSONObject: object
            )
        )
    }

    private func makeLaunchResult(
        manifest: PlayCoverPrepareManifest,
        sessionID: String,
        socketPath: String,
        logPath: String? = nil,
        reused: Bool
    ) -> PlayCoverSessionService.LaunchResult {
        .init(
            sessionID: sessionID,
            appPath: manifest.preparedAppPath,
            bundleIdentifier: manifest.bundleIdentifier,
            executablePath: manifest.executablePath,
            generationKey: manifest.generationKey,
            productType: "iPhone16,2",
            pid: 4_242,
            runtimeSocketPath: socketPath,
            logPath: logPath,
            reused: reused
        )
    }

    private func makeSessionInfo(
        manifest: PlayCoverPrepareManifest,
        sessionID: String,
        socketPath: String,
        logPath: String? = nil,
        startedAt: Int = Int(
            Date().timeIntervalSince1970 * 1_000
        )
    ) -> SessionService.Info {
        .init(
            udid: "playcover:\(manifest.bundleIdentifier)",
            deviceName: "iPhone16,2",
            deviceVersion: "Mac Catalyst",
            deviceType: PlayCoverSessionService.deviceType,
            startedAt: startedAt,
            runnerPid: 4_242,
            startMode: PlayCoverSessionService.deviceType,
            sessionIdentifier: sessionID,
            bundleId: manifest.bundleIdentifier,
            playCoverAppPath: manifest.preparedAppPath,
            playCoverExecutablePath: manifest.executablePath,
            playCoverGenerationKey: manifest.generationKey,
            playCoverRuntimeSocketPath: socketPath,
            playCoverLogPath: logPath
        )
    }

    private func replacing(
        _ info: SessionService.Info,
        appPath: String? = nil,
        executablePath: String? = nil,
        runtimeSocketPath: String? = nil,
        logPath: String? = nil
    ) -> SessionService.Info {
        .init(
            udid: info.udid,
            deviceName: info.deviceName,
            deviceVersion: info.deviceVersion,
            deviceType: info.deviceType,
            startedAt: info.startedAt,
            holderPid: info.holderPid,
            runnerPid: info.runnerPid,
            startMode: info.startMode,
            sessionIdentifier: info.sessionIdentifier,
            bundleId: info.bundleId,
            controlSocketPath: info.controlSocketPath,
            playCoverAppPath: appPath ?? info.playCoverAppPath,
            playCoverExecutablePath:
                executablePath
                ?? info.playCoverExecutablePath,
            playCoverGenerationKey:
                info.playCoverGenerationKey,
            playCoverRuntimeSocketPath:
                runtimeSocketPath
                ?? info.playCoverRuntimeSocketPath,
            playCoverLogPath:
                logPath ?? info.playCoverLogPath
        )
    }

    private func makeClientThatMustNotRun()
        -> DriverCommandClient
    {
        PlayCoverDriverClient(
            session: .init(
                udid: "unused",
                deviceName: "",
                deviceVersion: "",
                deviceType: PlayCoverSessionService.deviceType
            )
        ) { _, _, _ in
            throw CLIParseError.invalidValue(
                "unexpected Runtime request"
            )
        }
    }
}

private final class LockedReferenceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Void, Error>?

    var value: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Result<Void, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private struct SessionFixture {
    let root: String
    let paths: IOSUsePaths

    init() throws {
        root = "/tmp/iosuse-session-"
            + String(UUID().uuidString.prefix(8))
        paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root]
        )
        PlayCoverService.launchAliasRootOverrideForTesting =
            URL(
                fileURLWithPath: root,
                isDirectory: true
            ).appendingPathComponent(
                "launch-aliases",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverRun,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(paths.playcoverRun, 0o700)
    }

    func createManagedApp(
        manifest: PlayCoverPrepareManifest
    ) throws {
        try FileManager.default.createDirectory(
            atPath: manifest.preparedAppPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func createPreparedSidecars(
        manifest: PlayCoverPrepareManifest
    ) throws {
        let generation = URL(
            fileURLWithPath: manifest.preparedAppPath,
            isDirectory: true
        ).deletingLastPathComponent()
        for filename in [
            PlayCoverService.manifestFilename,
            PlayCoverService.completedFilename,
        ] {
            try Data("{}".utf8).write(
                to: generation.appendingPathComponent(filename)
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
