import Foundation
@testable import IOSUseCLI
import XCTest

final class PlayCoverSessionTests: XCTestCase {
    override func tearDown() {
        PlayCoverService.signingIdentityResolverOverrideForTesting = nil
        PlayCoverSessionService.launchOverrideForTesting = nil
        PlayCoverSessionService.terminateOverrideForTesting = nil
        PlayCoverSessionService.resolveSlotOverrideForTesting = nil
        PlayCoverSessionService.processStateOverrideForTesting = nil
        PlayCoverSessionService.processExecutablePathOverrideForTesting = nil
        PlayCoverSessionService.processStartTimeOverrideForTesting = nil
        PlayCoverSessionService.signalOverrideForTesting = nil
        PlayCoverSessionService.terminationIdentityProbeOverrideForTesting = nil
        PlayCoverSessionService.nowMillisecondsOverrideForTesting = nil
        PlayCoverSlotService.currentInstallRevisionOverrideForTesting = nil
        PlayCoverSlotLauncher.authenticateOverrideForTesting = nil
        PlayCoverSlotLauncher.processStateOverrideForTesting = nil
        PlayCoverSlotLauncher.processStartTimeOverrideForTesting = nil
        PlayCoverSlotLauncher.signalOverrideForTesting = nil
        #if canImport(AppKit)
        PlayCoverSlotLauncher.workspaceOpenOverrideForTesting = nil
        PlayCoverSlotLauncher.workspaceSubmissionObserverForTesting = nil
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = nil
        #endif
        super.tearDown()
    }

    func testSameBundleBlockRunsBeforeSlotPrepare() throws {
        #if canImport(AppKit)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var resolvedSlot = false
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = { _ in
            [777]
        }
        PlayCoverSessionService.resolveSlotOverrideForTesting = { _, _, _ in
            resolvedSlot = true
            return (fixture.slot, false)
        }

        XCTAssertThrowsError(
            try PlayCoverSessionService.launch(
                explicitAppPath: fixture.sourceApp.path,
                signingIdentity: signingIdentity(),
                timeout: 1,
                paths: fixture.paths
            )
        )
        XCTAssertFalse(resolvedSlot)
        #endif
    }

    func testSuccessfulStartCommitsInstallRevisionAndRemovesLaunching() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureNoRunningBundle()
        PlayCoverSessionService.resolveSlotOverrideForTesting = { _, _, _ in
            (fixture.slot, false)
        }
        PlayCoverSessionService.launchOverrideForTesting = {
            slot,
            sessionID,
            socket,
            _,
            _ in
            PlayCoverSessionService.LaunchResult(
                sessionID: sessionID,
                appPath: slot.appPath,
                bundleIdentifier: slot.metadata.bundleIdentifier,
                executablePath: slot.executablePath,
                installRevision: slot.metadata.installRevision,
                productType: "Mac",
                pid: 123,
                runtimeSocketPath: socket,
                logPath: nil,
                reused: false,
                recovered: false
            )
        }

        let output = try SessionService.startPlayCoverAfterPreflight(
            appPath: fixture.sourceApp.path,
            signingIdentity: signingIdentity(),
            timeout: 1,
            paths: fixture.paths
        )

        XCTAssertTrue(output.contains("Mac App slot installed"))
        let lock = try XCTUnwrap(
            SessionService.readDriverLockInfo(paths: fixture.paths)
        )
        XCTAssertEqual(lock.macInstallRevision, fixture.installRevision)
        XCTAssertNil(
            try PlayCoverLaunchingStore.load(paths: fixture.paths)
        )
    }

    func testEveryExplicitAppStartResolvesFreshInstall() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureNoRunningBundle()
        var installCount = 0
        PlayCoverSessionService.resolveSlotOverrideForTesting = {
            explicit,
            _,
            _ in
            XCTAssertNotNil(explicit)
            installCount += 1
            return (fixture.slot, false)
        }
        PlayCoverSessionService.launchOverrideForTesting = launchResult

        _ = try PlayCoverSessionService.launch(
            explicitAppPath: fixture.sourceApp.path,
            signingIdentity: signingIdentity(),
            timeout: 1,
            paths: fixture.paths
        )
        _ = try PlayCoverSessionService.launch(
            explicitAppPath: fixture.sourceApp.path,
            signingIdentity: signingIdentity(),
            timeout: 1,
            paths: fixture.paths
        )

        XCTAssertEqual(installCount, 2)
    }

    func testReuseReadsHomeBundleAndReturnsCurrentSlot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureNoRunningBundle()
        try PlayCoverHomeStore.updateCurrentBundle(
            fixture.bundleIdentifier,
            paths: fixture.paths
        )
        PlayCoverSessionService.resolveSlotOverrideForTesting = {
            explicit,
            signer,
            _ in
            XCTAssertNil(explicit)
            XCTAssertNil(signer)
            return (fixture.slot, true)
        }
        PlayCoverSessionService.launchOverrideForTesting = launchResult

        let result = try PlayCoverSessionService.launch(
            explicitAppPath: nil,
            timeout: 1,
            paths: fixture.paths
        )

        XCTAssertTrue(result.reused)
        XCTAssertEqual(result.bundleIdentifier, fixture.bundleIdentifier)
    }

    func testStaleLaunchingWithoutProcessIsRemoved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureNoRunningBundle()
        PlayCoverSlotService.currentInstallRevisionOverrideForTesting = { _ in
            fixture.installRevision
        }
        PlayCoverSessionService.nowMillisecondsOverrideForTesting = {
            120_000
        }
        let record = try launchingRecord(
            fixture: fixture,
            submittedAt: 1
        )
        try PlayCoverLaunchingStore.create(record, paths: fixture.paths)

        let recovered = try PlayCoverSessionService.recoverLaunching(
            timeout: 15,
            paths: fixture.paths
        )

        XCTAssertNil(recovered)
        XCTAssertNil(
            try PlayCoverLaunchingStore.load(paths: fixture.paths)
        )
    }

    func testAuthenticatedInterruptedLaunchIsAdoptedThenCommitted() throws {
        #if canImport(AppKit)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        PlayCoverSlotService.currentInstallRevisionOverrideForTesting = { _ in
            fixture.installRevision
        }
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = { _ in
            [321]
        }
        PlayCoverSlotLauncher.authenticateOverrideForTesting = {
            pid,
            slot,
            record,
            _ in
            self.hello(
                pid: pid,
                slot: slot,
                sessionID: record.sessionID
            )
        }
        let record = try launchingRecord(fixture: fixture, submittedAt: 1)
        try PlayCoverLaunchingStore.create(record, paths: fixture.paths)

        let recovered = try XCTUnwrap(
            PlayCoverSessionService.recoverLaunching(
                timeout: 15,
                paths: fixture.paths
            )
        )

        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.pid, 321)
        XCTAssertNotNil(
            try PlayCoverLaunchingStore.load(paths: fixture.paths)
        )
        try PlayCoverSessionService.finishDriverLockCommit(
            result: recovered,
            paths: fixture.paths
        )
        XCTAssertNil(
            try PlayCoverLaunchingStore.load(paths: fixture.paths)
        )
        #endif
    }

    func testRecentInterruptedLaunchPreservesTransientAuthentication()
        throws
    {
        #if canImport(AppKit)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        PlayCoverSlotService.currentInstallRevisionOverrideForTesting = { _ in
            fixture.installRevision
        }
        PlayCoverSessionService.nowMillisecondsOverrideForTesting = {
            10_000
        }
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = { _ in
            [654]
        }
        PlayCoverSlotLauncher.authenticateOverrideForTesting = { _, _, _, _ in
            throw PlayCoverRuntimeClientError.timeout(
                operation: "Runtime is still starting"
            )
        }
        let record = try launchingRecord(
            fixture: fixture,
            submittedAt: 1
        )
        try PlayCoverLaunchingStore.create(record, paths: fixture.paths)

        XCTAssertThrowsError(
            try PlayCoverSessionService.recoverLaunching(
                timeout: 15,
                paths: fixture.paths
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "the interrupted \(record.bundleIdentifier) launch has "
                        + "not authenticated yet"
                )
            )
        }
        XCTAssertEqual(
            try PlayCoverLaunchingStore.load(paths: fixture.paths),
            record
        )
        #endif
    }

    func testStopPreservesRecentNoProcessLaunchForLateWorkspaceStart()
        throws
    {
        #if canImport(AppKit)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureNoRunningBundle()
        PlayCoverSessionService.nowMillisecondsOverrideForTesting = {
            10_000
        }
        let record = try launchingRecord(
            fixture: fixture,
            submittedAt: 1
        )
        try PlayCoverLaunchingStore.create(record, paths: fixture.paths)

        XCTAssertThrowsError(
            try SessionService.stop(paths: fixture.paths)
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "still within its asynchronous submit window"
                )
            )
            XCTAssertTrue(
                MachineOutput.classify(error).retryable
            )
        }
        XCTAssertEqual(
            try PlayCoverLaunchingStore.load(paths: fixture.paths),
            record
        )
        #endif
    }

    func testStopClearsInterruptedLaunchWithoutRunningProcess() throws {
        #if canImport(AppKit)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureNoRunningBundle()
        try FileManager.default.createDirectory(
            atPath: fixture.paths.playcoverPlayChain,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let record = try launchingRecord(fixture: fixture, submittedAt: 1)
        try PlayCoverLaunchingStore.create(record, paths: fixture.paths)

        let output = try SessionService.stop(paths: fixture.paths)

        XCTAssertEqual(
            output,
            "Mac interrupted launch state cleared (no running App)\n"
                + "Mac session stopped\n"
        )
        XCTAssertNil(
            try PlayCoverLaunchingStore.load(paths: fixture.paths)
        )
        #endif
    }

    func testUnknownSameBundleProcessIsNeverTerminated() throws {
        #if canImport(AppKit)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        PlayCoverSlotService.currentInstallRevisionOverrideForTesting = { _ in
            fixture.installRevision
        }
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = { _ in
            [654]
        }
        PlayCoverSlotLauncher.authenticateOverrideForTesting = { _, _, _, _ in
            throw PlayCoverRuntimeClientError.timeout(
                operation: "test timeout"
            )
        }
        var signals: [Int32] = []
        PlayCoverSlotLauncher.signalOverrideForTesting = { _, signal in
            signals.append(signal)
            return 0
        }
        let record = try launchingRecord(fixture: fixture, submittedAt: 1)
        try PlayCoverLaunchingStore.create(record, paths: fixture.paths)

        XCTAssertThrowsError(
            try PlayCoverSessionService.recoverLaunching(
                timeout: 15,
                paths: fixture.paths
            )
        )
        XCTAssertTrue(signals.isEmpty)
        XCTAssertNil(
            try PlayCoverLaunchingStore.load(paths: fixture.paths)
        )
        #endif
    }

    func testTerminateRefusesChangedExecutableBeforeSignal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let info = sessionInfo(fixture: fixture, pid: 999)
        PlayCoverSessionService.processStateOverrideForTesting = { _ in
            .running(executablePath: "/tmp/not-the-slot")
        }
        var signals: [Int32] = []
        PlayCoverSessionService.signalOverrideForTesting = { _, signal in
            signals.append(signal)
            return 0
        }

        XCTAssertThrowsError(
            try PlayCoverSessionService.terminate(
                session: info,
                paths: fixture.paths
            )
        )
        XCTAssertTrue(signals.isEmpty)
    }

    private let launchResult: PlayCoverSessionService.LaunchOverride = {
        slot,
        sessionID,
        socket,
        _,
        _ in
        PlayCoverSessionService.LaunchResult(
            sessionID: sessionID,
            appPath: slot.appPath,
            bundleIdentifier: slot.metadata.bundleIdentifier,
            executablePath: slot.executablePath,
            installRevision: slot.metadata.installRevision,
            productType: "Mac",
            pid: 111,
            runtimeSocketPath: socket,
            logPath: nil,
            reused: true,
            recovered: false
        )
    }

    private struct Fixture {
        let root: URL
        let paths: IOSUsePaths
        let sourceApp: URL
        let slot: PlayCoverInstalledSlot
        let bundleIdentifier: String
        let installRevision: String
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(
            fileURLWithPath: "/tmp/iu-session-"
                + String(UUID().uuidString.prefix(8)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": root.appendingPathComponent("home").path,
            ],
            accountHomeDirectoryOverrideForTesting:
                root.appendingPathComponent("account").path,
            socketRootOverrideForTesting:
                root.appendingPathComponent("sockets").path
        )
        let bundleIdentifier = "com.example.demo"
        let installRevision = String(repeating: "a", count: 64)
        let sourceApp = root.appendingPathComponent("Source.app")
        try writeInfoPlist(bundleIdentifier, app: sourceApp)
        let slotDirectory = URL(
            fileURLWithPath: paths.playcoverApps,
            isDirectory: true
        ).appendingPathComponent(bundleIdentifier)
        let app = slotDirectory.appendingPathComponent("Demo.app")
        try writeInfoPlist(bundleIdentifier, app: app)
        for relative in [
            "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime",
            "Frameworks/IOSUseFridaEngine.framework/IOSUseFridaEngine",
        ] {
            let url = app.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("binary".utf8).write(to: url)
        }
        let executable = app.appendingPathComponent("Demo")
        try Data("binary".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let metadata = PlayCoverSlotMetadata(
            bundleIdentifier: bundleIdentifier,
            appRelativePath: "Demo.app",
            executableRelativePath: "Demo",
            installRevision: installRevision
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadataURL = slotDirectory.appendingPathComponent("slot.json")
        try encoder.encode(metadata).write(to: metadataURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: metadataURL.path
        )
        return Fixture(
            root: root,
            paths: paths,
            sourceApp: sourceApp,
            slot: PlayCoverInstalledSlot(
                metadata: metadata,
                appPath: app.path,
                executablePath: executable.path
            ),
            bundleIdentifier: bundleIdentifier,
            installRevision: installRevision
        )
    }

    private func writeInfoPlist(
        _ bundleIdentifier: String,
        app: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleExecutable": "Demo",
                "CFBundleDisplayName": "Demo",
            ],
            format: .binary,
            options: 0
        )
        try data.write(to: app.appendingPathComponent("Info.plist"))
    }

    private func launchingRecord(
        fixture: Fixture,
        submittedAt: Int64
    ) throws -> PlayCoverLaunchingStore.Record {
        let sessionID = UUID().uuidString
        return PlayCoverLaunchingStore.Record(
            sessionID: sessionID,
            runtimeSocketPath: try fixture.paths.macRuntimeSocketPath(
                sessionID: sessionID
            ),
            bundleIdentifier: fixture.bundleIdentifier,
            executableRelativePath: "Demo",
            submittedAt: submittedAt,
            logPath: nil
        )
    }

    private func hello(
        pid: Int32,
        slot: PlayCoverInstalledSlot,
        sessionID: String
    ) -> PlayCoverHello {
        PlayCoverHello(
            sessionID: sessionID,
            pid: pid,
            bundleIdentifier: slot.metadata.bundleIdentifier,
            executablePath: slot.executablePath,
            installRevision: slot.metadata.installRevision,
            controlStage: "ready",
            uiState: "ready",
            uiStage: "ready",
            uiFailure: nil,
            capabilities: ["hello", "debug"]
        )
    }

    private func sessionInfo(
        fixture: Fixture,
        pid: Int
    ) -> SessionService.Info {
        let sessionID = UUID().uuidString
        return SessionService.Info(
            udid: "mac",
            deviceName: "Mac",
            deviceVersion: "Mac Catalyst",
            deviceType: "mac",
            runnerPid: pid,
            startMode: "mac",
            sessionIdentifier: sessionID,
            bundleId: fixture.bundleIdentifier,
            macAppPath: fixture.slot.appPath,
            macExecutablePath: fixture.slot.executablePath,
            macInstallRevision: fixture.installRevision,
            macRuntimeSocketPath: try! fixture.paths.macRuntimeSocketPath(
                sessionID: sessionID
            )
        )
    }

    private func signingIdentity() -> PlayCoverSigningIdentityEvidence {
        PlayCoverSigningIdentityEvidence(
            publicKeySPKISHA256: String(repeating: "A", count: 64),
            certificateSHA256: String(repeating: "B", count: 64),
            codesignSelector: String(repeating: "C", count: 40),
            notBefore: Date().addingTimeInterval(-60),
            notAfter: Date().addingTimeInterval(60),
            policy: PlayCoverSigningIdentityPolicyEvidence(
                revision: PlayCoverSigningIdentityService.policyRevision,
                source: .managedUserKeychain,
                health: .healthy
            )
        )
    }

    private func configureNoRunningBundle() {
        #if canImport(AppKit)
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = { _ in
            []
        }
        #endif
    }
}
