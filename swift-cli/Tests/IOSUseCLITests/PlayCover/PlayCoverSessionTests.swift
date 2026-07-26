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
        PlayCoverManagedAppService.inspectOverrideForTesting = nil
        PlayCoverManagedAppService.verifyOverrideForTesting = nil
        PlayCoverManagedAppService.fastVerifyOverrideForTesting = nil
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
        XCTAssertEqual(
            fastVerificationPaths,
            [
                manifest.preparedAppPath,
                manifest.preparedAppPath,
            ]
        )
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
            _, _, _, _ in
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
                "does not match the verified generation"
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
        )
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
            _, _, _, _ in
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
            _, sessionID, socketPath, _ in
            let result = self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socketPath,
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
        ).run(arguments: ["start", "--playcover"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(
            terminated?.sessionIdentifier,
            launched?.sessionID
        )
        XCTAssertEqual(
            terminated?.playCoverRuntimeSocketPath,
            launched?.runtimeSocketPath
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.driverLock
            )
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
            _, sessionID, socketPath, _ in
            let result = self.makeLaunchResult(
                manifest: manifest,
                sessionID: sessionID,
                socketPath: socketPath,
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
        ).run(arguments: ["start", "--playcover"])

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

    private enum LockMutation: CaseIterable {
        case socket
        case app
        case executable
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
        hostCaptureError: String? = nil
    ) -> PlayCoverRuntimeResponsePayload {
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
            stage: "ready"
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
            canvasBounds: .init(x: 0, y: 0, width: 430, height: 932),
            displayScale: 0.75,
            inverseDisplayScale: 4.0 / 3.0,
            transparentSpacer: 0,
            transparent: false,
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
            canvasBounds: host.canvasBounds,
            displayScale: host.displayScale,
            inverseDisplayScale: host.inverseDisplayScale,
            transparentSpacer: host.transparentSpacer,
            transparent: host.transparent,
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
            reused: reused
        )
    }

    private func makeSessionInfo(
        manifest: PlayCoverPrepareManifest,
        sessionID: String,
        socketPath: String,
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
            playCoverRuntimeSocketPath: socketPath
        )
    }

    private func replacing(
        _ info: SessionService.Info,
        appPath: String? = nil,
        executablePath: String? = nil,
        runtimeSocketPath: String? = nil
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
                ?? info.playCoverRuntimeSocketPath
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

private struct SessionFixture {
    let root: String
    let paths: IOSUsePaths

    init() throws {
        root = "/tmp/iosuse-session-"
            + String(UUID().uuidString.prefix(8))
        paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root]
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

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
